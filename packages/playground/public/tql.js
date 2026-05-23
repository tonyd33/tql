var Iovec = class Iovec {
	static read_bytes(view, ptr) {
		const iovec = new Iovec();
		iovec.buf = view.getUint32(ptr, true);
		iovec.buf_len = view.getUint32(ptr + 4, true);
		return iovec;
	}
	static read_bytes_array(view, ptr, len) {
		const iovecs = [];
		for (let i = 0; i < len; i++) iovecs.push(Iovec.read_bytes(view, ptr + 8 * i));
		return iovecs;
	}
};
var Ciovec = class Ciovec {
	static read_bytes(view, ptr) {
		const iovec = new Ciovec();
		iovec.buf = view.getUint32(ptr, true);
		iovec.buf_len = view.getUint32(ptr + 4, true);
		return iovec;
	}
	static read_bytes_array(view, ptr, len) {
		const iovecs = [];
		for (let i = 0; i < len; i++) iovecs.push(Ciovec.read_bytes(view, ptr + 8 * i));
		return iovecs;
	}
};
var Dirent = class {
	head_length() {
		return 24;
	}
	name_length() {
		return this.dir_name.byteLength;
	}
	write_head_bytes(view, ptr) {
		view.setBigUint64(ptr, this.d_next, true);
		view.setBigUint64(ptr + 8, this.d_ino, true);
		view.setUint32(ptr + 16, this.dir_name.length, true);
		view.setUint8(ptr + 20, this.d_type);
	}
	write_name_bytes(view8, ptr, buf_len) {
		view8.set(this.dir_name.slice(0, Math.min(this.dir_name.byteLength, buf_len)), ptr);
	}
	constructor(next_cookie, d_ino, name, type) {
		const encoded_name = new TextEncoder().encode(name);
		this.d_next = next_cookie;
		this.d_ino = d_ino;
		this.d_namlen = encoded_name.byteLength;
		this.d_type = type;
		this.dir_name = encoded_name;
	}
};
var Fdstat = class {
	write_bytes(view, ptr) {
		view.setUint8(ptr, this.fs_filetype);
		view.setUint16(ptr + 2, this.fs_flags, true);
		view.setBigUint64(ptr + 8, this.fs_rights_base, true);
		view.setBigUint64(ptr + 16, this.fs_rights_inherited, true);
	}
	constructor(filetype, flags) {
		this.fs_rights_base = 0n;
		this.fs_rights_inherited = 0n;
		this.fs_filetype = filetype;
		this.fs_flags = flags;
	}
};
var Filestat = class {
	write_bytes(view, ptr) {
		view.setBigUint64(ptr, this.dev, true);
		view.setBigUint64(ptr + 8, this.ino, true);
		view.setUint8(ptr + 16, this.filetype);
		view.setBigUint64(ptr + 24, this.nlink, true);
		view.setBigUint64(ptr + 32, this.size, true);
		view.setBigUint64(ptr + 38, this.atim, true);
		view.setBigUint64(ptr + 46, this.mtim, true);
		view.setBigUint64(ptr + 52, this.ctim, true);
	}
	constructor(ino, filetype, size) {
		this.dev = 0n;
		this.nlink = 0n;
		this.atim = 0n;
		this.mtim = 0n;
		this.ctim = 0n;
		this.ino = ino;
		this.filetype = filetype;
		this.size = size;
	}
};
var Subscription = class Subscription {
	static read_bytes(view, ptr) {
		return new Subscription(view.getBigUint64(ptr, true), view.getUint8(ptr + 8), view.getUint32(ptr + 16, true), view.getBigUint64(ptr + 24, true), view.getUint16(ptr + 36, true));
	}
	constructor(userdata, eventtype, clockid, timeout, flags) {
		this.userdata = userdata;
		this.eventtype = eventtype;
		this.clockid = clockid;
		this.timeout = timeout;
		this.flags = flags;
	}
};
var Event = class {
	write_bytes(view, ptr) {
		view.setBigUint64(ptr, this.userdata, true);
		view.setUint16(ptr + 8, this.error, true);
		view.setUint8(ptr + 10, this.eventtype);
	}
	constructor(userdata, error, eventtype) {
		this.userdata = userdata;
		this.error = error;
		this.eventtype = eventtype;
	}
};
var PrestatDir = class {
	write_bytes(view, ptr) {
		view.setUint32(ptr, this.pr_name.byteLength, true);
	}
	constructor(name) {
		this.pr_name = new TextEncoder().encode(name);
	}
};
var Prestat = class Prestat {
	static dir(name) {
		const prestat = new Prestat();
		prestat.tag = 0;
		prestat.inner = new PrestatDir(name);
		return prestat;
	}
	write_bytes(view, ptr) {
		view.setUint32(ptr, this.tag, true);
		this.inner.write_bytes(view, ptr + 4);
	}
};
//#endregion
//#region ../../node_modules/.pnpm/@bjorn3+browser_wasi_shim@0.4.2/node_modules/@bjorn3/browser_wasi_shim/dist/debug.js
let Debug = class Debug {
	enable(enabled) {
		this.log = createLogger(enabled === void 0 ? true : enabled, this.prefix);
	}
	get enabled() {
		return this.isEnabled;
	}
	constructor(isEnabled) {
		this.isEnabled = isEnabled;
		this.prefix = "wasi:";
		this.enable(isEnabled);
	}
};
function createLogger(enabled, prefix) {
	if (enabled) return console.log.bind(console, "%c%s", "color: #265BA0", prefix);
	else return () => {};
}
const debug = new Debug(false);
//#endregion
//#region ../../node_modules/.pnpm/@bjorn3+browser_wasi_shim@0.4.2/node_modules/@bjorn3/browser_wasi_shim/dist/wasi.js
var WASIProcExit = class extends Error {
	constructor(code) {
		super("exit with exit code " + code);
		this.code = code;
	}
};
let WASI = class WASI {
	start(instance) {
		this.inst = instance;
		try {
			instance.exports._start();
			return 0;
		} catch (e) {
			if (e instanceof WASIProcExit) return e.code;
			else throw e;
		}
	}
	initialize(instance) {
		this.inst = instance;
		if (instance.exports._initialize) instance.exports._initialize();
	}
	constructor(args, env, fds, options = {}) {
		this.args = [];
		this.env = [];
		this.fds = [];
		debug.enable(options.debug);
		this.args = args;
		this.env = env;
		this.fds = fds;
		const self = this;
		this.wasiImport = {
			args_sizes_get(argc, argv_buf_size) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				buffer.setUint32(argc, self.args.length, true);
				let buf_size = 0;
				for (const arg of self.args) buf_size += arg.length + 1;
				buffer.setUint32(argv_buf_size, buf_size, true);
				debug.log(buffer.getUint32(argc, true), buffer.getUint32(argv_buf_size, true));
				return 0;
			},
			args_get(argv, argv_buf) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				const orig_argv_buf = argv_buf;
				for (let i = 0; i < self.args.length; i++) {
					buffer.setUint32(argv, argv_buf, true);
					argv += 4;
					const arg = new TextEncoder().encode(self.args[i]);
					buffer8.set(arg, argv_buf);
					buffer.setUint8(argv_buf + arg.length, 0);
					argv_buf += arg.length + 1;
				}
				if (debug.enabled) debug.log(new TextDecoder("utf-8").decode(buffer8.slice(orig_argv_buf, argv_buf)));
				return 0;
			},
			environ_sizes_get(environ_count, environ_size) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				buffer.setUint32(environ_count, self.env.length, true);
				let buf_size = 0;
				for (const environ of self.env) buf_size += new TextEncoder().encode(environ).length + 1;
				buffer.setUint32(environ_size, buf_size, true);
				debug.log(buffer.getUint32(environ_count, true), buffer.getUint32(environ_size, true));
				return 0;
			},
			environ_get(environ, environ_buf) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				const orig_environ_buf = environ_buf;
				for (let i = 0; i < self.env.length; i++) {
					buffer.setUint32(environ, environ_buf, true);
					environ += 4;
					const e = new TextEncoder().encode(self.env[i]);
					buffer8.set(e, environ_buf);
					buffer.setUint8(environ_buf + e.length, 0);
					environ_buf += e.length + 1;
				}
				if (debug.enabled) debug.log(new TextDecoder("utf-8").decode(buffer8.slice(orig_environ_buf, environ_buf)));
				return 0;
			},
			clock_res_get(id, res_ptr) {
				let resolutionValue;
				switch (id) {
					case 1:
						resolutionValue = 5000n;
						break;
					case 0:
						resolutionValue = 1000000n;
						break;
					default: return 52;
				}
				new DataView(self.inst.exports.memory.buffer).setBigUint64(res_ptr, resolutionValue, true);
				return 0;
			},
			clock_time_get(id, precision, time) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				if (id === 0) buffer.setBigUint64(time, BigInt((/* @__PURE__ */ new Date()).getTime()) * 1000000n, true);
				else if (id == 1) {
					let monotonic_time;
					try {
						monotonic_time = BigInt(Math.round(performance.now() * 1e6));
					} catch (e) {
						monotonic_time = 0n;
					}
					buffer.setBigUint64(time, monotonic_time, true);
				} else buffer.setBigUint64(time, 0n, true);
				return 0;
			},
			fd_advise(fd, offset, len, advice) {
				if (self.fds[fd] != void 0) return 0;
				else return 8;
			},
			fd_allocate(fd, offset, len) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_allocate(offset, len);
				else return 8;
			},
			fd_close(fd) {
				if (self.fds[fd] != void 0) {
					const ret = self.fds[fd].fd_close();
					self.fds[fd] = void 0;
					return ret;
				} else return 8;
			},
			fd_datasync(fd) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_sync();
				else return 8;
			},
			fd_fdstat_get(fd, fdstat_ptr) {
				if (self.fds[fd] != void 0) {
					const { ret, fdstat } = self.fds[fd].fd_fdstat_get();
					if (fdstat != null) fdstat.write_bytes(new DataView(self.inst.exports.memory.buffer), fdstat_ptr);
					return ret;
				} else return 8;
			},
			fd_fdstat_set_flags(fd, flags) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_fdstat_set_flags(flags);
				else return 8;
			},
			fd_fdstat_set_rights(fd, fs_rights_base, fs_rights_inheriting) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_fdstat_set_rights(fs_rights_base, fs_rights_inheriting);
				else return 8;
			},
			fd_filestat_get(fd, filestat_ptr) {
				if (self.fds[fd] != void 0) {
					const { ret, filestat } = self.fds[fd].fd_filestat_get();
					if (filestat != null) filestat.write_bytes(new DataView(self.inst.exports.memory.buffer), filestat_ptr);
					return ret;
				} else return 8;
			},
			fd_filestat_set_size(fd, size) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_filestat_set_size(size);
				else return 8;
			},
			fd_filestat_set_times(fd, atim, mtim, fst_flags) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_filestat_set_times(atim, mtim, fst_flags);
				else return 8;
			},
			fd_pread(fd, iovs_ptr, iovs_len, offset, nread_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const iovecs = Iovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
					let nread = 0;
					for (const iovec of iovecs) {
						const { ret, data } = self.fds[fd].fd_pread(iovec.buf_len, offset);
						if (ret != 0) {
							buffer.setUint32(nread_ptr, nread, true);
							return ret;
						}
						buffer8.set(data, iovec.buf);
						nread += data.length;
						offset += BigInt(data.length);
						if (data.length != iovec.buf_len) break;
					}
					buffer.setUint32(nread_ptr, nread, true);
					return 0;
				} else return 8;
			},
			fd_prestat_get(fd, buf_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const { ret, prestat } = self.fds[fd].fd_prestat_get();
					if (prestat != null) prestat.write_bytes(buffer, buf_ptr);
					return ret;
				} else return 8;
			},
			fd_prestat_dir_name(fd, path_ptr, path_len) {
				if (self.fds[fd] != void 0) {
					const { ret, prestat } = self.fds[fd].fd_prestat_get();
					if (prestat == null) return ret;
					const prestat_dir_name = prestat.inner.pr_name;
					new Uint8Array(self.inst.exports.memory.buffer).set(prestat_dir_name.slice(0, path_len), path_ptr);
					return prestat_dir_name.byteLength > path_len ? 37 : 0;
				} else return 8;
			},
			fd_pwrite(fd, iovs_ptr, iovs_len, offset, nwritten_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const iovecs = Ciovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
					let nwritten = 0;
					for (const iovec of iovecs) {
						const data = buffer8.slice(iovec.buf, iovec.buf + iovec.buf_len);
						const { ret, nwritten: nwritten_part } = self.fds[fd].fd_pwrite(data, offset);
						if (ret != 0) {
							buffer.setUint32(nwritten_ptr, nwritten, true);
							return ret;
						}
						nwritten += nwritten_part;
						offset += BigInt(nwritten_part);
						if (nwritten_part != data.byteLength) break;
					}
					buffer.setUint32(nwritten_ptr, nwritten, true);
					return 0;
				} else return 8;
			},
			fd_read(fd, iovs_ptr, iovs_len, nread_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const iovecs = Iovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
					let nread = 0;
					for (const iovec of iovecs) {
						const { ret, data } = self.fds[fd].fd_read(iovec.buf_len);
						if (ret != 0) {
							buffer.setUint32(nread_ptr, nread, true);
							return ret;
						}
						buffer8.set(data, iovec.buf);
						nread += data.length;
						if (data.length != iovec.buf_len) break;
					}
					buffer.setUint32(nread_ptr, nread, true);
					return 0;
				} else return 8;
			},
			fd_readdir(fd, buf, buf_len, cookie, bufused_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					let bufused = 0;
					while (true) {
						const { ret, dirent } = self.fds[fd].fd_readdir_single(cookie);
						if (ret != 0) {
							buffer.setUint32(bufused_ptr, bufused, true);
							return ret;
						}
						if (dirent == null) break;
						if (buf_len - bufused < dirent.head_length()) {
							bufused = buf_len;
							break;
						}
						const head_bytes = new ArrayBuffer(dirent.head_length());
						dirent.write_head_bytes(new DataView(head_bytes), 0);
						buffer8.set(new Uint8Array(head_bytes).slice(0, Math.min(head_bytes.byteLength, buf_len - bufused)), buf);
						buf += dirent.head_length();
						bufused += dirent.head_length();
						if (buf_len - bufused < dirent.name_length()) {
							bufused = buf_len;
							break;
						}
						dirent.write_name_bytes(buffer8, buf, buf_len - bufused);
						buf += dirent.name_length();
						bufused += dirent.name_length();
						cookie = dirent.d_next;
					}
					buffer.setUint32(bufused_ptr, bufused, true);
					return 0;
				} else return 8;
			},
			fd_renumber(fd, to) {
				if (self.fds[fd] != void 0 && self.fds[to] != void 0) {
					const ret = self.fds[to].fd_close();
					if (ret != 0) return ret;
					self.fds[to] = self.fds[fd];
					self.fds[fd] = void 0;
					return 0;
				} else return 8;
			},
			fd_seek(fd, offset, whence, offset_out_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const { ret, offset: offset_out } = self.fds[fd].fd_seek(offset, whence);
					buffer.setBigInt64(offset_out_ptr, offset_out, true);
					return ret;
				} else return 8;
			},
			fd_sync(fd) {
				if (self.fds[fd] != void 0) return self.fds[fd].fd_sync();
				else return 8;
			},
			fd_tell(fd, offset_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const { ret, offset } = self.fds[fd].fd_tell();
					buffer.setBigUint64(offset_ptr, offset, true);
					return ret;
				} else return 8;
			},
			fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const iovecs = Ciovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
					let nwritten = 0;
					for (const iovec of iovecs) {
						const data = buffer8.slice(iovec.buf, iovec.buf + iovec.buf_len);
						const { ret, nwritten: nwritten_part } = self.fds[fd].fd_write(data);
						if (ret != 0) {
							buffer.setUint32(nwritten_ptr, nwritten, true);
							return ret;
						}
						nwritten += nwritten_part;
						if (nwritten_part != data.byteLength) break;
					}
					buffer.setUint32(nwritten_ptr, nwritten, true);
					return 0;
				} else return 8;
			},
			path_create_directory(fd, path_ptr, path_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					return self.fds[fd].path_create_directory(path);
				} else return 8;
			},
			path_filestat_get(fd, flags, path_ptr, path_len, filestat_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					const { ret, filestat } = self.fds[fd].path_filestat_get(flags, path);
					if (filestat != null) filestat.write_bytes(buffer, filestat_ptr);
					return ret;
				} else return 8;
			},
			path_filestat_set_times(fd, flags, path_ptr, path_len, atim, mtim, fst_flags) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					return self.fds[fd].path_filestat_set_times(flags, path, atim, mtim, fst_flags);
				} else return 8;
			},
			path_link(old_fd, old_flags, old_path_ptr, old_path_len, new_fd, new_path_ptr, new_path_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[old_fd] != void 0 && self.fds[new_fd] != void 0) {
					const old_path = new TextDecoder("utf-8").decode(buffer8.slice(old_path_ptr, old_path_ptr + old_path_len));
					const new_path = new TextDecoder("utf-8").decode(buffer8.slice(new_path_ptr, new_path_ptr + new_path_len));
					const { ret, inode_obj } = self.fds[old_fd].path_lookup(old_path, old_flags);
					if (inode_obj == null) return ret;
					return self.fds[new_fd].path_link(new_path, inode_obj, false);
				} else return 8;
			},
			path_open(fd, dirflags, path_ptr, path_len, oflags, fs_rights_base, fs_rights_inheriting, fd_flags, opened_fd_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					debug.log(path);
					const { ret, fd_obj } = self.fds[fd].path_open(dirflags, path, oflags, fs_rights_base, fs_rights_inheriting, fd_flags);
					if (ret != 0) return ret;
					self.fds.push(fd_obj);
					const opened_fd = self.fds.length - 1;
					buffer.setUint32(opened_fd_ptr, opened_fd, true);
					return 0;
				} else return 8;
			},
			path_readlink(fd, path_ptr, path_len, buf_ptr, buf_len, nread_ptr) {
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					debug.log(path);
					const { ret, data } = self.fds[fd].path_readlink(path);
					if (data != null) {
						const data_buf = new TextEncoder().encode(data);
						if (data_buf.length > buf_len) {
							buffer.setUint32(nread_ptr, 0, true);
							return 8;
						}
						buffer8.set(data_buf, buf_ptr);
						buffer.setUint32(nread_ptr, data_buf.length, true);
					}
					return ret;
				} else return 8;
			},
			path_remove_directory(fd, path_ptr, path_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					return self.fds[fd].path_remove_directory(path);
				} else return 8;
			},
			path_rename(fd, old_path_ptr, old_path_len, new_fd, new_path_ptr, new_path_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0 && self.fds[new_fd] != void 0) {
					const old_path = new TextDecoder("utf-8").decode(buffer8.slice(old_path_ptr, old_path_ptr + old_path_len));
					const new_path = new TextDecoder("utf-8").decode(buffer8.slice(new_path_ptr, new_path_ptr + new_path_len));
					let { ret, inode_obj } = self.fds[fd].path_unlink(old_path);
					if (inode_obj == null) return ret;
					ret = self.fds[new_fd].path_link(new_path, inode_obj, true);
					if (ret != 0) {
						if (self.fds[fd].path_link(old_path, inode_obj, true) != 0) throw "path_link should always return success when relinking an inode back to the original place";
					}
					return ret;
				} else return 8;
			},
			path_symlink(old_path_ptr, old_path_len, fd, new_path_ptr, new_path_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					new TextDecoder("utf-8").decode(buffer8.slice(old_path_ptr, old_path_ptr + old_path_len));
					new TextDecoder("utf-8").decode(buffer8.slice(new_path_ptr, new_path_ptr + new_path_len));
					return 58;
				} else return 8;
			},
			path_unlink_file(fd, path_ptr, path_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
				if (self.fds[fd] != void 0) {
					const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
					return self.fds[fd].path_unlink_file(path);
				} else return 8;
			},
			poll_oneoff(in_ptr, out_ptr, nsubscriptions) {
				if (nsubscriptions === 0) return 28;
				if (nsubscriptions > 1) {
					debug.log("poll_oneoff: only a single subscription is supported");
					return 58;
				}
				const buffer = new DataView(self.inst.exports.memory.buffer);
				const s = Subscription.read_bytes(buffer, in_ptr);
				const eventtype = s.eventtype;
				const clockid = s.clockid;
				const timeout = s.timeout;
				if (eventtype !== 0) {
					debug.log("poll_oneoff: only clock subscriptions are supported");
					return 58;
				}
				let getNow = void 0;
				if (clockid === 1) getNow = () => BigInt(Math.round(performance.now() * 1e6));
				else if (clockid === 0) getNow = () => BigInt((/* @__PURE__ */ new Date()).getTime()) * 1000000n;
				else return 28;
				const endTime = (s.flags & 1) !== 0 ? timeout : getNow() + timeout;
				while (endTime > getNow());
				new Event(s.userdata, 0, eventtype).write_bytes(buffer, out_ptr);
				return 0;
			},
			proc_exit(exit_code) {
				throw new WASIProcExit(exit_code);
			},
			proc_raise(sig) {
				throw "raised signal " + sig;
			},
			sched_yield() {},
			random_get(buf, buf_len) {
				const buffer8 = new Uint8Array(self.inst.exports.memory.buffer).subarray(buf, buf + buf_len);
				if ("crypto" in globalThis && (typeof SharedArrayBuffer === "undefined" || !(self.inst.exports.memory.buffer instanceof SharedArrayBuffer))) for (let i = 0; i < buf_len; i += 65536) crypto.getRandomValues(buffer8.subarray(i, i + 65536));
				else for (let i = 0; i < buf_len; i++) buffer8[i] = Math.random() * 256 | 0;
			},
			sock_recv(fd, ri_data, ri_flags) {
				throw "sockets not supported";
			},
			sock_send(fd, si_data, si_flags) {
				throw "sockets not supported";
			},
			sock_shutdown(fd, how) {
				throw "sockets not supported";
			},
			sock_accept(fd, flags) {
				throw "sockets not supported";
			}
		};
	}
};
//#endregion
//#region ../../node_modules/.pnpm/@bjorn3+browser_wasi_shim@0.4.2/node_modules/@bjorn3/browser_wasi_shim/dist/fd.js
var Fd = class {
	fd_allocate(offset, len) {
		return 58;
	}
	fd_close() {
		return 0;
	}
	fd_fdstat_get() {
		return {
			ret: 58,
			fdstat: null
		};
	}
	fd_fdstat_set_flags(flags) {
		return 58;
	}
	fd_fdstat_set_rights(fs_rights_base, fs_rights_inheriting) {
		return 58;
	}
	fd_filestat_get() {
		return {
			ret: 58,
			filestat: null
		};
	}
	fd_filestat_set_size(size) {
		return 58;
	}
	fd_filestat_set_times(atim, mtim, fst_flags) {
		return 58;
	}
	fd_pread(size, offset) {
		return {
			ret: 58,
			data: new Uint8Array()
		};
	}
	fd_prestat_get() {
		return {
			ret: 58,
			prestat: null
		};
	}
	fd_pwrite(data, offset) {
		return {
			ret: 58,
			nwritten: 0
		};
	}
	fd_read(size) {
		return {
			ret: 58,
			data: new Uint8Array()
		};
	}
	fd_readdir_single(cookie) {
		return {
			ret: 58,
			dirent: null
		};
	}
	fd_seek(offset, whence) {
		return {
			ret: 58,
			offset: 0n
		};
	}
	fd_sync() {
		return 0;
	}
	fd_tell() {
		return {
			ret: 58,
			offset: 0n
		};
	}
	fd_write(data) {
		return {
			ret: 58,
			nwritten: 0
		};
	}
	path_create_directory(path) {
		return 58;
	}
	path_filestat_get(flags, path) {
		return {
			ret: 58,
			filestat: null
		};
	}
	path_filestat_set_times(flags, path, atim, mtim, fst_flags) {
		return 58;
	}
	path_link(path, inode, allow_dir) {
		return 58;
	}
	path_unlink(path) {
		return {
			ret: 58,
			inode_obj: null
		};
	}
	path_lookup(path, dirflags) {
		return {
			ret: 58,
			inode_obj: null
		};
	}
	path_open(dirflags, path, oflags, fs_rights_base, fs_rights_inheriting, fd_flags) {
		return {
			ret: 54,
			fd_obj: null
		};
	}
	path_readlink(path) {
		return {
			ret: 58,
			data: null
		};
	}
	path_remove_directory(path) {
		return 58;
	}
	path_rename(old_path, new_fd, new_path) {
		return 58;
	}
	path_unlink_file(path) {
		return 58;
	}
};
var Inode = class Inode {
	static issue_ino() {
		return Inode.next_ino++;
	}
	static root_ino() {
		return 0n;
	}
	constructor() {
		this.ino = Inode.issue_ino();
	}
};
Inode.next_ino = 1n;
//#endregion
//#region ../../node_modules/.pnpm/@bjorn3+browser_wasi_shim@0.4.2/node_modules/@bjorn3/browser_wasi_shim/dist/fs_mem.js
var OpenFile = class extends Fd {
	fd_allocate(offset, len) {
		if (this.file.size > offset + len) {} else {
			const new_data = new Uint8Array(Number(offset + len));
			new_data.set(this.file.data, 0);
			this.file.data = new_data;
		}
		return 0;
	}
	fd_fdstat_get() {
		return {
			ret: 0,
			fdstat: new Fdstat(4, 0)
		};
	}
	fd_filestat_set_size(size) {
		if (this.file.size > size) this.file.data = new Uint8Array(this.file.data.buffer.slice(0, Number(size)));
		else {
			const new_data = new Uint8Array(Number(size));
			new_data.set(this.file.data, 0);
			this.file.data = new_data;
		}
		return 0;
	}
	fd_read(size) {
		const slice = this.file.data.slice(Number(this.file_pos), Number(this.file_pos + BigInt(size)));
		this.file_pos += BigInt(slice.length);
		return {
			ret: 0,
			data: slice
		};
	}
	fd_pread(size, offset) {
		return {
			ret: 0,
			data: this.file.data.slice(Number(offset), Number(offset + BigInt(size)))
		};
	}
	fd_seek(offset, whence) {
		let calculated_offset;
		switch (whence) {
			case 0:
				calculated_offset = offset;
				break;
			case 1:
				calculated_offset = this.file_pos + offset;
				break;
			case 2:
				calculated_offset = BigInt(this.file.data.byteLength) + offset;
				break;
			default: return {
				ret: 28,
				offset: 0n
			};
		}
		if (calculated_offset < 0) return {
			ret: 28,
			offset: 0n
		};
		this.file_pos = calculated_offset;
		return {
			ret: 0,
			offset: this.file_pos
		};
	}
	fd_tell() {
		return {
			ret: 0,
			offset: this.file_pos
		};
	}
	fd_write(data) {
		if (this.file.readonly) return {
			ret: 8,
			nwritten: 0
		};
		if (this.file_pos + BigInt(data.byteLength) > this.file.size) {
			const old = this.file.data;
			this.file.data = new Uint8Array(Number(this.file_pos + BigInt(data.byteLength)));
			this.file.data.set(old);
		}
		this.file.data.set(data, Number(this.file_pos));
		this.file_pos += BigInt(data.byteLength);
		return {
			ret: 0,
			nwritten: data.byteLength
		};
	}
	fd_pwrite(data, offset) {
		if (this.file.readonly) return {
			ret: 8,
			nwritten: 0
		};
		if (offset + BigInt(data.byteLength) > this.file.size) {
			const old = this.file.data;
			this.file.data = new Uint8Array(Number(offset + BigInt(data.byteLength)));
			this.file.data.set(old);
		}
		this.file.data.set(data, Number(offset));
		return {
			ret: 0,
			nwritten: data.byteLength
		};
	}
	fd_filestat_get() {
		return {
			ret: 0,
			filestat: this.file.stat()
		};
	}
	constructor(file) {
		super();
		this.file_pos = 0n;
		this.file = file;
	}
};
var OpenDirectory = class extends Fd {
	fd_seek(offset, whence) {
		return {
			ret: 8,
			offset: 0n
		};
	}
	fd_tell() {
		return {
			ret: 8,
			offset: 0n
		};
	}
	fd_allocate(offset, len) {
		return 8;
	}
	fd_fdstat_get() {
		return {
			ret: 0,
			fdstat: new Fdstat(3, 0)
		};
	}
	fd_readdir_single(cookie) {
		if (debug.enabled) {
			debug.log("readdir_single", cookie);
			debug.log(cookie, this.dir.contents.keys());
		}
		if (cookie == 0n) return {
			ret: 0,
			dirent: new Dirent(1n, this.dir.ino, ".", 3)
		};
		else if (cookie == 1n) return {
			ret: 0,
			dirent: new Dirent(2n, this.dir.parent_ino(), "..", 3)
		};
		if (cookie >= BigInt(this.dir.contents.size) + 2n) return {
			ret: 0,
			dirent: null
		};
		const [name, entry] = Array.from(this.dir.contents.entries())[Number(cookie - 2n)];
		return {
			ret: 0,
			dirent: new Dirent(cookie + 1n, entry.ino, name, entry.stat().filetype)
		};
	}
	path_filestat_get(flags, path_str) {
		const { ret: path_err, path } = Path.from(path_str);
		if (path == null) return {
			ret: path_err,
			filestat: null
		};
		const { ret, entry } = this.dir.get_entry_for_path(path);
		if (entry == null) return {
			ret,
			filestat: null
		};
		return {
			ret: 0,
			filestat: entry.stat()
		};
	}
	path_lookup(path_str, dirflags) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return {
			ret: path_ret,
			inode_obj: null
		};
		const { ret, entry } = this.dir.get_entry_for_path(path);
		if (entry == null) return {
			ret,
			inode_obj: null
		};
		return {
			ret: 0,
			inode_obj: entry
		};
	}
	path_open(dirflags, path_str, oflags, fs_rights_base, fs_rights_inheriting, fd_flags) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return {
			ret: path_ret,
			fd_obj: null
		};
		let { ret, entry } = this.dir.get_entry_for_path(path);
		if (entry == null) {
			if (ret != 44) return {
				ret,
				fd_obj: null
			};
			if ((oflags & 1) == 1) {
				const { ret, entry: new_entry } = this.dir.create_entry_for_path(path_str, (oflags & 2) == 2);
				if (new_entry == null) return {
					ret,
					fd_obj: null
				};
				entry = new_entry;
			} else return {
				ret: 44,
				fd_obj: null
			};
		} else if ((oflags & 4) == 4) return {
			ret: 20,
			fd_obj: null
		};
		if ((oflags & 2) == 2 && entry.stat().filetype !== 3) return {
			ret: 54,
			fd_obj: null
		};
		return entry.path_open(oflags, fs_rights_base, fd_flags);
	}
	path_create_directory(path) {
		return this.path_open(0, path, 3, 0n, 0n, 0).ret;
	}
	path_link(path_str, inode, allow_dir) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return path_ret;
		if (path.is_dir) return 44;
		const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, true);
		if (parent_entry == null || filename == null) return parent_ret;
		if (entry != null) {
			const source_is_dir = inode.stat().filetype == 3;
			const target_is_dir = entry.stat().filetype == 3;
			if (source_is_dir && target_is_dir) if (allow_dir && entry instanceof Directory) if (entry.contents.size == 0) {} else return 55;
			else return 20;
			else if (source_is_dir && !target_is_dir) return 54;
			else if (!source_is_dir && target_is_dir) return 31;
			else if (inode.stat().filetype == 4 && entry.stat().filetype == 4) {} else return 20;
		}
		if (!allow_dir && inode.stat().filetype == 3) return 63;
		parent_entry.contents.set(filename, inode);
		return 0;
	}
	path_unlink(path_str) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return {
			ret: path_ret,
			inode_obj: null
		};
		const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, true);
		if (parent_entry == null || filename == null) return {
			ret: parent_ret,
			inode_obj: null
		};
		if (entry == null) return {
			ret: 44,
			inode_obj: null
		};
		parent_entry.contents.delete(filename);
		return {
			ret: 0,
			inode_obj: entry
		};
	}
	path_unlink_file(path_str) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return path_ret;
		const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, false);
		if (parent_entry == null || filename == null || entry == null) return parent_ret;
		if (entry.stat().filetype === 3) return 31;
		parent_entry.contents.delete(filename);
		return 0;
	}
	path_remove_directory(path_str) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return path_ret;
		const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, false);
		if (parent_entry == null || filename == null || entry == null) return parent_ret;
		if (!(entry instanceof Directory) || entry.stat().filetype !== 3) return 54;
		if (entry.contents.size !== 0) return 55;
		if (!parent_entry.contents.delete(filename)) return 44;
		return 0;
	}
	fd_filestat_get() {
		return {
			ret: 0,
			filestat: this.dir.stat()
		};
	}
	fd_filestat_set_size(size) {
		return 8;
	}
	fd_read(size) {
		return {
			ret: 8,
			data: new Uint8Array()
		};
	}
	fd_pread(size, offset) {
		return {
			ret: 8,
			data: new Uint8Array()
		};
	}
	fd_write(data) {
		return {
			ret: 8,
			nwritten: 0
		};
	}
	fd_pwrite(data, offset) {
		return {
			ret: 8,
			nwritten: 0
		};
	}
	constructor(dir) {
		super();
		this.dir = dir;
	}
};
var PreopenDirectory = class extends OpenDirectory {
	fd_prestat_get() {
		return {
			ret: 0,
			prestat: Prestat.dir(this.prestat_name)
		};
	}
	constructor(name, contents) {
		super(new Directory(contents));
		this.prestat_name = name;
	}
};
var File = class extends Inode {
	path_open(oflags, fs_rights_base, fd_flags) {
		if (this.readonly && (fs_rights_base & BigInt(64)) == BigInt(64)) return {
			ret: 63,
			fd_obj: null
		};
		if ((oflags & 8) == 8) {
			if (this.readonly) return {
				ret: 63,
				fd_obj: null
			};
			this.data = new Uint8Array([]);
		}
		const file = new OpenFile(this);
		if (fd_flags & 1) file.fd_seek(0n, 2);
		return {
			ret: 0,
			fd_obj: file
		};
	}
	get size() {
		return BigInt(this.data.byteLength);
	}
	stat() {
		return new Filestat(this.ino, 4, this.size);
	}
	constructor(data, options) {
		super();
		this.data = new Uint8Array(data);
		this.readonly = !!options?.readonly;
	}
};
let Path = class Path {
	static from(path) {
		const self = new Path();
		self.is_dir = path.endsWith("/");
		if (path.startsWith("/")) return {
			ret: 76,
			path: null
		};
		if (path.includes("\0")) return {
			ret: 28,
			path: null
		};
		for (const component of path.split("/")) {
			if (component === "" || component === ".") continue;
			if (component === "..") {
				if (self.parts.pop() == void 0) return {
					ret: 76,
					path: null
				};
				continue;
			}
			self.parts.push(component);
		}
		return {
			ret: 0,
			path: self
		};
	}
	to_path_string() {
		let s = this.parts.join("/");
		if (this.is_dir) s += "/";
		return s;
	}
	constructor() {
		this.parts = [];
		this.is_dir = false;
	}
};
var Directory = class Directory extends Inode {
	parent_ino() {
		if (this.parent == null) return Inode.root_ino();
		return this.parent.ino;
	}
	path_open(oflags, fs_rights_base, fd_flags) {
		return {
			ret: 0,
			fd_obj: new OpenDirectory(this)
		};
	}
	stat() {
		return new Filestat(this.ino, 3, 0n);
	}
	get_entry_for_path(path) {
		let entry = this;
		for (const component of path.parts) {
			if (!(entry instanceof Directory)) return {
				ret: 54,
				entry: null
			};
			const child = entry.contents.get(component);
			if (child !== void 0) entry = child;
			else {
				debug.log(component);
				return {
					ret: 44,
					entry: null
				};
			}
		}
		if (path.is_dir) {
			if (entry.stat().filetype != 3) return {
				ret: 54,
				entry: null
			};
		}
		return {
			ret: 0,
			entry
		};
	}
	get_parent_dir_and_entry_for_path(path, allow_undefined) {
		const filename = path.parts.pop();
		if (filename === void 0) return {
			ret: 28,
			parent_entry: null,
			filename: null,
			entry: null
		};
		const { ret: entry_ret, entry: parent_entry } = this.get_entry_for_path(path);
		if (parent_entry == null) return {
			ret: entry_ret,
			parent_entry: null,
			filename: null,
			entry: null
		};
		if (!(parent_entry instanceof Directory)) return {
			ret: 54,
			parent_entry: null,
			filename: null,
			entry: null
		};
		const entry = parent_entry.contents.get(filename);
		if (entry === void 0) if (!allow_undefined) return {
			ret: 44,
			parent_entry: null,
			filename: null,
			entry: null
		};
		else return {
			ret: 0,
			parent_entry,
			filename,
			entry: null
		};
		if (path.is_dir) {
			if (entry.stat().filetype != 3) return {
				ret: 54,
				parent_entry: null,
				filename: null,
				entry: null
			};
		}
		return {
			ret: 0,
			parent_entry,
			filename,
			entry
		};
	}
	create_entry_for_path(path_str, is_dir) {
		const { ret: path_ret, path } = Path.from(path_str);
		if (path == null) return {
			ret: path_ret,
			entry: null
		};
		let { ret: parent_ret, parent_entry, filename, entry } = this.get_parent_dir_and_entry_for_path(path, true);
		if (parent_entry == null || filename == null) return {
			ret: parent_ret,
			entry: null
		};
		if (entry != null) return {
			ret: 20,
			entry: null
		};
		debug.log("create", path);
		let new_child;
		if (!is_dir) new_child = new File(/* @__PURE__ */ new ArrayBuffer(0));
		else new_child = new Directory(/* @__PURE__ */ new Map());
		parent_entry.contents.set(filename, new_child);
		entry = new_child;
		return {
			ret: 0,
			entry
		};
	}
	constructor(contents) {
		super();
		this.parent = null;
		if (contents instanceof Array) this.contents = new Map(contents);
		else this.contents = contents;
		for (const entry of this.contents.values()) if (entry instanceof Directory) entry.parent = this;
	}
};
var ConsoleStdout = class ConsoleStdout extends Fd {
	fd_filestat_get() {
		return {
			ret: 0,
			filestat: new Filestat(this.ino, 2, BigInt(0))
		};
	}
	fd_fdstat_get() {
		const fdstat = new Fdstat(2, 0);
		fdstat.fs_rights_base = BigInt(64);
		return {
			ret: 0,
			fdstat
		};
	}
	fd_write(data) {
		this.write(data);
		return {
			ret: 0,
			nwritten: data.byteLength
		};
	}
	static lineBuffered(write) {
		const dec = new TextDecoder("utf-8", { fatal: false });
		let line_buf = "";
		return new ConsoleStdout((buffer) => {
			line_buf += dec.decode(buffer, { stream: true });
			const lines = line_buf.split("\n");
			for (const [i, line] of lines.entries()) if (i < lines.length - 1) write(line);
			else line_buf = line;
		});
	}
	constructor(write) {
		super();
		this.ino = Inode.issue_ino();
		this.write = write;
	}
};
//#endregion
//#region src/tql.ts
const LANG = {
	c: 0,
	typescript: 1,
	tsx: 2
};
async function start() {
	const wasi = new WASI([
		"bin",
		"arg1",
		"arg2"
	], ["FOO=bar"], [
		new OpenFile(new File([])),
		ConsoleStdout.lineBuffered((msg) => console.log(`[WASI stdout] ${msg}`)),
		ConsoleStdout.lineBuffered((msg) => console.warn(`[WASI stderr] ${msg}`)),
		new PreopenDirectory(".", [["example.c", new File(new TextEncoder("utf-8").encode(`#include "a"`))], ["hello.rs", new File(new TextEncoder("utf-8").encode(`fn main() { println!("Hello World!"); }`))]])
	]);
	const wasm = await WebAssembly.compileStreaming(fetch("./tql.wasm"));
	const instance = await WebAssembly.instantiate(wasm, { "wasi_snapshot_preview1": wasi.wasiImport });
	wasi.initialize(instance);
	const exp = instance.exports;
	const mem = exp.memory;
	const writeStr = (s) => {
		const buf = new TextEncoder().encode(s);
		const ptr = exp.tql_alloc(buf.length);
		new Uint8Array(mem.buffer, ptr, buf.length).set(buf);
		return {
			ptr,
			len: buf.length
		};
	};
	const readStr = (ptrFn, lenFn) => new TextDecoder().decode(new Uint8Array(mem.buffer, ptrFn(), lenFn()));
	const query = "select function_definition.declarator";
	const source = `
int add(int a, int b) { return a + b; }
int main(void) { return add(1, 2); }
`;
	const q = writeStr(query);
	const t = writeStr(source);
	if (exp.tql_run(LANG.c, q.ptr, q.len, t.ptr, t.len) !== 0) {
		console.error("tql_run failed:", readStr(exp.tql_last_error_ptr, exp.tql_last_error_len));
		process.exit(1);
	}
	const result = JSON.parse(readStr(exp.tql_last_result_ptr, exp.tql_last_result_len));
	console.log(result);
	exp.tql_free(q.ptr, q.len);
	exp.tql_free(t.ptr, t.len);
}
//#endregion
export { start };
