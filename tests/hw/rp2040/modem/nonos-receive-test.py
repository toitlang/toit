#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Reproduce NONOS passive-receive use-after-free from a local SDK checkout.

This is a host source-level diagnostic, not a modem firmware test. It compiles
Espressif's actual callback and pbuf_free with minimal host transport stubs.
The corrected variant copies every chained payload before freeing the chain.
No source is downloaded and no device is accessed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

STUBS = r"""
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef uint8_t u8_t; typedef uint16_t u16_t; typedef int err_t;
#define ERR_OK 0
#define ESPCONN_MEM -1
#define ESPCONN_READ 5
#define ESPCONN_CONNECT 3
#define ESTABLISHED 4
#define TCP_WND 2920
#define PBUF_RAM 0
#define PBUF_ROM 1
#define PBUF_REF 2
#define PBUF_POOL 3
#define LWIP_SUPPORT_CUSTOM_PBUF 0
#define LWIP_ASSERT(a,b) assert(b)
#define LWIP_DEBUGF(a,b)
#define PERF_START
#define PERF_STOP(a)
#define SYS_ARCH_DECL_PROTECT(a)
#define SYS_ARCH_PROTECT(a)
#define SYS_ARCH_UNPROTECT(a)
#define MEMP_PBUF_POOL 0
#define MEMP_PBUF 1
#define memp_free(a,b) free(b)
#define mem_free(a) free(a)
struct pbuf { struct pbuf *next; void *payload; u16_t tot_len, len; u8_t type, flags; u16_t ref; };
struct tcp_pcb { int state; };
struct espconn { int state; void (*recv_callback)(struct espconn*, void*, size_t); };
struct ring { size_t used; uint8_t bytes[2920]; };
typedef struct { struct ring *readbuf; struct { int recv_check; struct tcp_pcb *pcb; } pcommon; struct espconn *pespconn; void *preverse; } espconn_msg;
static void tcp_arg(struct tcp_pcb *p, void *a) {}
static struct ring *ringbuf_new(int n) { return calloc(1,sizeof(struct ring)); }
static void *ringbuf_memcpy_into(struct ring *r, const void *src, size_t n) { assert(r->used+n<=2920); memcpy(r->bytes+r->used,src,n); r->used+=n; return r->bytes+r->used; }
static size_t ringbuf_bytes_used(struct ring *r) { return r->used; }
static void espconn_server_close(void *a, void *b,int c) {}
static void espconn_client_close(void *a, void *b,int c) {}
"""

MAIN = r"""
int main(void) {
  struct pbuf *a=calloc(1,sizeof(*a)), *b=calloc(1,sizeof(*b));
  a->next=b; a->payload="abc"; a->len=3; a->tot_len=6; a->ref=1;
  b->payload="def"; b->len=b->tot_len=3; b->ref=1;
  struct tcp_pcb pcb={ESTABLISHED}; struct espconn conn={0};
  espconn_msg msg={.pespconn=&conn};
  assert(espconn_tcp_recv(&msg,&pcb,a,ERR_OK)==ERR_OK);
  assert(msg.readbuf->used==6); assert(memcmp(msg.readbuf->bytes,"abcdef",6)==0);
  free(msg.readbuf); puts("PASS: both chained payloads copied");
}
"""


def body(path, name):
    text = path.read_text(errors="replace")
    start = text.index("\n" + name + "(")
    start = text.index("{", start)
    end, depth = start + 1, 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receive = args.sdk / "third_party/lwip/app/espconn_tcp.c"
    release = args.sdk / "third_party/lwip/core/pbuf.c"
    free_function = "static u8_t pbuf_free(struct pbuf *p)\n" + body(release, "pbuf_free")
    declaration = "static err_t espconn_tcp_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)\n"
    original = declaration + body(receive, "espconn_tcp_recv")
    old_loop = """                if (ring)
                    pbuf_free(pthis);
                else
                    break;"""
    if original.count(old_loop) != 1:
        raise RuntimeError("SDK callback differs from the reviewed NONOS 3.0.6 source")
    fixed = original.replace(old_loop, "                if (!ring) break;")
    fixed = fixed.replace("            bytes_used = ringbuf_bytes_used(precv_cb->readbuf);",
                          "            pbuf_free(p);\n            bytes_used = ringbuf_bytes_used(precv_cb->readbuf);")
    results = {}
    for name, callback in [("original", original), ("fixed", fixed)]:
        source = args.output / (name + ".c")
        executable = args.output / name
        source.write_text(STUBS + free_function + "\n" + callback + "\n" + MAIN)
        subprocess.run([args.cc, "-g", "-fsanitize=address", "-fno-omit-frame-pointer",
                        str(source), "-o", str(executable)], check=True)
        # LeakSanitizer cannot run under some sandbox tracers; ASan stays on.
        result = subprocess.run([str(executable.resolve())], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
        (args.output / (name + ".log")).write_text(result.stdout)
        if name == "original":
            assert result.returncode != 0 and "heap-use-after-free" in result.stdout
        else:
            assert result.returncode == 0 and "both chained payloads copied" in result.stdout
        results[name] = result.returncode
    results["source_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [receive, release]}
    (args.output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    print("PASS: original callback triggers ASan; copy-before-free variant preserves both payloads")


if __name__ == "__main__":
    main()
