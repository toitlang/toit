// Copyright (C) 2021 Toitware ApS.
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

package compiler

import (
	"encoding/binary"
	"io"

	"go.uber.org/zap"
)

type multiplexConn struct {
	FSToCompiler     *pipe
	CompilerToFS     *pipe
	CompilerToParser *pipe

	logger       *zap.Logger
	toCompiler   io.WriteCloser
	fromCompiler io.ReadCloser
}

func newMultiplexConn(logger *zap.Logger) *multiplexConn {
	return &multiplexConn{
		logger:           logger,
		FSToCompiler:     newPipe(),
		CompilerToFS:     newPipe(),
		CompilerToParser: newPipe(),
	}
}

func (mpc *multiplexConn) setFromCompiler(fromCompiler io.ReadCloser) {
	mpc.fromCompiler = fromCompiler
	go mpc.dispatch()
}

func (mpc *multiplexConn) setToCompiler(toCompiler io.WriteCloser) {
	mpc.toCompiler = toCompiler
	go mpc.copyAndClose(mpc.FSToCompiler.r, toCompiler)
}

func (mpc *multiplexConn) Close() {
	mpc.FSToCompiler.Close()
	mpc.CompilerToFS.Close()
	mpc.CompilerToParser.Close()
	mpc.toCompiler.Close()
	mpc.fromCompiler.Close()
}

func (mpc *multiplexConn) dispatch() {
	defer mpc.CompilerToFS.w.Close()
	defer mpc.CompilerToParser.w.Close()

	from := mpc.fromCompiler
	toFS := mpc.CompilerToFS.w
	toParser := mpc.CompilerToParser.w
	for {
		var size int32
		err := binary.Read(from, binary.LittleEndian, &size)
		if err == io.EOF {
			break
		}
		if err != nil {
			mpc.logger.Debug("Error while reading from compiler", zap.Error(err))
			break
		}

		to := toParser
		if size < 0 {
			size = -size
			to = toFS
		}
		written, err := io.CopyN(to, from, int64(size))
		if err != nil {
			mpc.logger.Debug("Error while reading from compiler", zap.Error(err))
			break
		}
		if written != int64(size) {
			mpc.logger.Debug("Error while copying data from compiler", zap.Error(err))
			break
		}
	}
}

func (mpc *multiplexConn) copyAndClose(from io.ReadCloser, to io.WriteCloser) {
	defer from.Close()
	defer to.Close()
	_, err := io.Copy(to, from)
	if err != nil {
		mpc.logger.Debug("Piping finished with error", zap.Error(err))
	}
}

type pipe struct {
	r io.ReadCloser
	w io.WriteCloser
}

func newPipe() *pipe {
	r, w := io.Pipe()
	return &pipe{
		r: r,
		w: w,
	}
}

func (p *pipe) Close() error {
	err_read := p.r.Close()
	err_write := p.w.Close()
	if err_read != nil {
		return err_read
	}
	return err_write
}
