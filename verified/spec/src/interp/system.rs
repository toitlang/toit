// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

//! The world outside the process: stdout, the mailbox, a virtual clock with
//! timers, and an emulated system process that answers the RPCs the core
//! library makes during service discovery.
//!
//! Emulated system process (pid 0; the program runs as pid 1):
//! * RPC 300 (services open) to pid -1 for the service-discovery service
//!   (client id 0, hard-coded in the system process): answers with a
//!   service definition `[client, name, major, minor, patch, tags]`.
//! * RPC 302 (services invoke) on that client, method 0 (discover): answers
//!   null, i.e. "no provider". `print` then falls back to
//!   `StandardPrintService_`, which calls `core.write_on_stdout`.
//! * RPC 301 (services close): answers null.
//! * Anything else sent to the system process is answered with an RPC
//!   exception "UNIMPLEMENTED" so that the program sees a Toit exception
//!   rather than hanging.
//!
//! Replies are delivered as mailbox messages `[4, gid 0, pid 0, reply]`
//! (SYSTEM_RPC_REPLY), decoded into fresh heap objects when the program
//! calls `core.task_receive_message`.

use super::*;
use std::collections::VecDeque;

/// A message value, independent of any heap.
#[derive(Clone, Debug)]
pub enum MsgValue {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Bytes(Vec<u8>),
    List(Vec<MsgValue>),
}

pub enum Message {
    /// A system message: [type, gid, pid, payload].
    System(i64, MsgValue),
    /// A monitor to notify (timer/event notification).
    Monitor(Value),
}

pub struct Timer {
    pub id: i64,
    pub deadline: Option<i64>,
    pub monitor: Option<Value>,
}

pub struct World {
    pub args: Vec<String>,
    pub mailbox: VecDeque<Message>,
    /// Virtual monotonic clock in microseconds.
    pub clock_us: i64,
    pub timers: Vec<Timer>,
    pub next_resource_id: i64,
    pub stdout: Vec<u8>,
    pub echo: bool,
    pub finalizers: Vec<Value>,
    pub random: u64,
}

pub const SYSTEM_PID: i64 = 0;
pub const OWN_PID: i64 = 1;
const SYSTEM_RPC_REQUEST: i64 = 3;
const SYSTEM_RPC_REPLY: i64 = 4;

impl World {
    pub fn new(args: Vec<String>) -> World {
        World {
            args,
            mailbox: VecDeque::new(),
            clock_us: 1_000_000,
            timers: Vec::new(),
            next_resource_id: 1,
            stdout: Vec::new(),
            echo: true,
            finalizers: Vec::new(),
            random: 0x2545_f491_4f6c_dd1d,
        }
    }

    pub fn write_stdout(&mut self, bytes: &[u8]) {
        use std::io::Write;
        self.stdout.extend_from_slice(bytes);
        if self.echo {
            let mut out = std::io::stdout();
            let _ = out.write_all(bytes);
            let _ = out.flush();
        }
    }

    fn reply(&mut self, id: MsgValue, result: Result<MsgValue, String>) {
        let reply = match result {
            Ok(v) => MsgValue::List(vec![id, MsgValue::Bool(false), v]),
            Err(e) => MsgValue::List(vec![id, MsgValue::Bool(true), MsgValue::Str(e), MsgValue::Null]),
        };
        self.mailbox.push_back(Message::System(SYSTEM_RPC_REPLY, reply));
    }

    /// `process_send` to the system process.
    pub fn send_to_system(&mut self, ty: i64, msg: MsgValue) -> bool {
        if ty != SYSTEM_RPC_REQUEST {
            return true;  // Accepted and ignored (e.g. RPC cancel).
        }
        let parts = match msg {
            MsgValue::List(p) if p.len() >= 3 => p,
            _ => return true,
        };
        let id = parts[0].clone();
        let name = match parts[1] { MsgValue::Int(n) => n, _ => -1 };
        let args = &parts[2];
        let result = match (name, args) {
            (300, MsgValue::List(a)) if a.first().map(|c| matches!(c, MsgValue::Int(0))).unwrap_or(false) => {
                // Open the service-discovery service.
                Ok(MsgValue::List(vec![
                    MsgValue::Int(0),
                    MsgValue::Str("system/service-discovery".to_string()),
                    MsgValue::Int(0),
                    MsgValue::Int(1),
                    MsgValue::Int(0),
                    MsgValue::List(vec![]),
                ]))
            }
            (302, MsgValue::List(a)) if a.len() >= 2 && matches!(a[1], MsgValue::Int(0)) => {
                // discover uuid --wait: no provider.
                Ok(MsgValue::Null)
            }
            (301, _) => Ok(MsgValue::Null),
            _ => Err("UNIMPLEMENTED".to_string()),
        };
        self.reply(id, result);
        true
    }
}

/// HALT 0: the process yields. It is resumed when it has a message; if it
/// has none, the virtual clock advances to the next armed timer, whose
/// monitor is then put in the mailbox. With neither, the process would
/// sleep forever.
pub fn on_yield(m: &mut Machine) -> Result<(), End> {
    if !m.world.mailbox.is_empty() {
        return Ok(());
    }
    let next = m.world.timers.iter().enumerate()
        .filter(|(_, t)| t.deadline.is_some() && t.monitor.is_some())
        .min_by_key(|(_, t)| t.deadline.unwrap())
        .map(|(i, _)| i);
    match next {
        Some(i) => {
            let deadline = m.world.timers[i].deadline.take().unwrap();
            if deadline > m.world.clock_us {
                m.world.clock_us = deadline;
            }
            let monitor = m.world.timers[i].monitor.unwrap();
            m.world.mailbox.push_back(Message::Monitor(monitor));
            Ok(())
        }
        None => Err(End::Deadlock),
    }
}
