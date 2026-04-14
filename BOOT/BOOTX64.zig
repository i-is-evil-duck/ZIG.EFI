const std = @import("std");
const uefi = std.os.uefi;

const ConOut = uefi.protocol.SimpleTextOutput;
const ConIn = uefi.protocol.SimpleTextInput;
const InputEx = uefi.protocol.SimpleTextInputEx;
const FileProtocol = uefi.protocol.File;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const FileInfo = uefi.FileInfo;

const file_info_guid align(8) = uefi.Guid{
    .time_low = 0x09576e92,
    .time_mid = 0x6d3f,
    .time_high_and_version = 0x11d2,
    .clock_seq_high_and_reserved = 0x8e,
    .clock_seq_low = 0x39,
    .node = [_]u8{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
};

const CTRL_S = 0x13;
const CTRL_X = 0x18;

var current_dir: [256]u8 = undefined;
var current_dir_len: usize = 1;

pub fn main() uefi.Status {
    current_dir[0] = '/';
    const st = uefi.system_table;
    const out = st.con_out orelse return .DeviceError;
    const in = st.con_in orelse return .DeviceError;

    if (out.reset(false) != .Success) return .DeviceError;
    _ = out.clearScreen();

    print(out, "\nMiniOS v1.0\n");
    print(out, "Type 'help' for commands.\n\n");

    var buffer: [128]u8 = undefined;

    while (true) {
        print(out, "MiniOS> ");

        const len = readLine(in, out, &buffer) catch {
            print(out, "Input error\n");
            continue;
        };
        const line = buffer[0..len];

        handleCommand(line, out, in);
    }
}

fn handleCommand(cmd: []const u8, out: *ConOut, in: *ConIn) void {
    if (std.mem.eql(u8, cmd, "help")) {
        print(out,
            \\Commands:
            \\  help        - Show this message
            \\  clear       - Clear screen
            \\  ls          - List files
            \\  cd DIR      - Change directory
            \\  pwd         - Show current directory
            \\  shutdown    - Power off
            \\  reboot      - Reboot system
            \\  echo TEXT   - Print TEXT
            \\  snek        - Play snake (WASD, C to exit)
            \\  nano FILE   - Edit file (ESC: Menu)
            \\  testkeeb    - Test keyboard (ESC to exit)
            \\
        );
    } else if (std.mem.eql(u8, cmd, "clear")) {
        _ = out.clearScreen();
        _ = out.setCursorPosition(0, 0);
    } else if (std.mem.eql(u8, cmd, "shutdown")) {
        const rs = uefi.system_table.runtime_services;
        rs.resetSystem(.ResetShutdown, .Success, 0, null);
    } else if (std.mem.eql(u8, cmd, "reboot")) {
        const rs = uefi.system_table.runtime_services;
        rs.resetSystem(.ResetCold, .Success, 0, null);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        listFiles(out, current_dir[0..current_dir_len]) catch {
            print(out, "Error listing files\n");
        };
    } else if (std.mem.startsWith(u8, cmd, "cd ")) {
        const path = cmd[3..];
        if (!changeDirectory(path)) {
            print(out, "Directory not found\n");
        }
    } else if (std.mem.eql(u8, cmd, "pwd")) {
        print(out, current_dir[0..current_dir_len]);
        print(out, "\n");
    } else if (std.mem.startsWith(u8, cmd, "echo ")) {
        print(out, cmd[5..]);
        print(out, "\n");
    } else if (std.mem.eql(u8, cmd, "snek")) {
        runSnake(out, in) catch {
            print(out, "Game error\n");
        };
    } else if (std.mem.eql(u8, cmd, "testkeeb") or std.mem.eql(u8, cmd, "test keyboard")) {
        testKeyboard(out) catch {
            print(out, "Test error\n");
        };
    } else if (std.mem.startsWith(u8, cmd, "nano ")) {
        const filename = cmd[5..];
        if (filename.len == 0) {
            print(out, "Usage: nano <filename>\n");
            return;
        }
        runNano(out, in, filename) catch {
            print(out, "Editor error\n");
        };
    } else if (cmd.len == 0) {
        // empty
    } else {
        print(out, "Unknown command. Type 'help'.\n");
    }
}

// ============================================
// NANO EDITOR
// ============================================

const MAX_LINES = 100;
const MAX_COLS = 80;
const MAX_FILE_SIZE = 32 * 1024;

const EditorState = struct {
    lines: [MAX_LINES][MAX_COLS]u8,
    line_lens: [MAX_LINES]usize,
    num_lines: usize,
    cursor_x: usize,
    cursor_y: usize,
    scroll_y: usize,
    filename: []const u8,
};

fn runNano(out: *ConOut, _: *ConIn, filename: []const u8) !void {
    var state = EditorState{
        .lines = undefined,
        .line_lens = [_]usize{0} ** MAX_LINES,
        .num_lines = 1,
        .cursor_x = 0,
        .cursor_y = 0,
        .scroll_y = 0,
        .filename = filename,
    };

    @memset(&state.lines[0], 0);
    try loadFile(&state, filename);

    const input_ex = try getInputEx();
    _ = out.clearScreen();
    drawEditor(out, &state);

    while (true) {
        drawEditor(out, &state);

        const key = try readKeyRaw(input_ex);

        // Handle arrow keys
        switch (key.input.scan_code) {
            0x17 => { // Down
                if (state.cursor_y < state.num_lines - 1) {
                    state.cursor_y += 1;
                    state.cursor_x = @min(state.cursor_x, state.line_lens[state.cursor_y]);
                }
            },
            0x18 => { // Up
                if (state.cursor_y > 0) {
                    state.cursor_y -= 1;
                    state.cursor_x = @min(state.cursor_x, state.line_lens[state.cursor_y]);
                }
            },
            0x19 => { // Left
                if (state.cursor_x > 0) {
                    state.cursor_x -= 1;
                } else if (state.cursor_y > 0) {
                    state.cursor_y -= 1;
                    state.cursor_x = state.line_lens[state.cursor_y];
                }
            },
            0x1A => { // Right
                if (state.cursor_x < state.line_lens[state.cursor_y]) {
                    state.cursor_x += 1;
                } else if (state.cursor_y < state.num_lines - 1) {
                    state.cursor_y += 1;
                    state.cursor_x = 0;
                }
            },
            else => {},
        }

        // Handle regular input (no Ctrl detection, use ESC for menu)
        if (key.input.unicode_char == '\r' or key.input.unicode_char == '\n') {
            try insertNewline(&state);
        } else if (key.input.unicode_char == '\x08' or key.input.unicode_char == 0x7F) {
            try backspace(&state);
        } else if (key.input.unicode_char >= 32 and key.input.unicode_char < 127) {
            try insertChar(&state, @intCast(key.input.unicode_char));
        } else if (key.input.scan_code == 0x17) { // ESC
            // Show menu
            _ = out.clearScreen();
            print(out, "=== Menu ===\n");
            print(out, "S - Save file\n");
            print(out, "X - Exit without saving\n");
            print(out, "ESC - Return to editor\n\n");
            print(out, "Press key: ");

            const menu_key = try readKeyRaw(input_ex);

            if (menu_key.input.scan_code == 0x17) { // ESC - go back
                _ = out.clearScreen();
                drawEditor(out, &state);
            } else if (menu_key.input.unicode_char == 's' or menu_key.input.unicode_char == 'S') {
                if (saveFile(&state, filename)) {
                    showMessage(out, "Saved!", &state);
                } else |_| {
                    showMessage(out, "Save failed!", &state);
                }
            } else if (menu_key.input.unicode_char == 'x' or menu_key.input.unicode_char == 'X') {
                _ = out.clearScreen();
                print(out, "Exited without saving\n");
                return;
            }
        }
    }
}

fn drawEditor(out: *ConOut, state: *EditorState) void {
    _ = out.setCursorPosition(0, 0);

    var status_buf: [80]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "MiniNano - {s} [ESC: Menu]", .{state.filename}) catch "MiniNano";
    print(out, status);
    print(out, "\n");
    print(out, "------------------------------------------------------------------------------\n");

    const screen_height = 20;
    const start_y = state.scroll_y;
    _ = @min(start_y + screen_height, state.num_lines);

    var row: usize = 0;
    while (row < screen_height) : (row += 1) {
        const line_idx = start_y + row;
        if (line_idx < state.num_lines) {
            const len = state.line_lens[line_idx];
            if (len > 0) {
                printSlice(out, state.lines[line_idx][0..len]);
            }
        }
        print(out, "\n");
    }

    const screen_y = state.cursor_y - state.scroll_y + 2;
    _ = out.setCursorPosition(@intCast(state.cursor_x), @intCast(screen_y));
}

fn printSlice(out: *ConOut, s: []const u8) void {
    for (s) |c| {
        var utf16: [2:0]u16 = .{ c, 0 };
        _ = out.outputString(&utf16);
    }
}

fn insertChar(state: *EditorState, c: u8) !void {
    if (state.cursor_y >= MAX_LINES) return error.NoSpace;
    if (state.cursor_x >= MAX_COLS - 1) return error.NoSpace;
    if (state.line_lens[state.cursor_y] >= MAX_COLS - 1) return error.NoSpace;

    const line = &state.lines[state.cursor_y];
    const len = state.line_lens[state.cursor_y];

    var i: usize = len;
    while (i > state.cursor_x) : (i -= 1) {
        line[i] = line[i - 1];
    }

    line[state.cursor_x] = c;
    state.line_lens[state.cursor_y] += 1;
    state.cursor_x += 1;
}

fn backspace(state: *EditorState) !void {
    if (state.cursor_x > 0) {
        const line = &state.lines[state.cursor_y];
        const len = state.line_lens[state.cursor_y];

        var i: usize = state.cursor_x - 1;
        while (i < len - 1) : (i += 1) {
            line[i] = line[i + 1];
        }

        state.line_lens[state.cursor_y] -= 1;
        state.cursor_x -= 1;
    } else if (state.cursor_y > 0) {
        const prev_len = state.line_lens[state.cursor_y - 1];
        const curr_len = state.line_lens[state.cursor_y];

        if (prev_len + curr_len >= MAX_COLS) return error.NoSpace;

        @memcpy(state.lines[state.cursor_y - 1][prev_len..][0..curr_len], state.lines[state.cursor_y][0..curr_len]);
        state.line_lens[state.cursor_y - 1] += curr_len;

        var y: usize = state.cursor_y;
        while (y < state.num_lines - 1) : (y += 1) {
            @memcpy(state.lines[y][0..MAX_COLS], state.lines[y + 1][0..MAX_COLS]);
            state.line_lens[y] = state.line_lens[y + 1];
        }

        state.num_lines -= 1;
        state.cursor_y -= 1;
        state.cursor_x = prev_len;
    }
}

fn insertNewline(state: *EditorState) !void {
    if (state.num_lines >= MAX_LINES) return error.NoSpace;

    var y: usize = state.num_lines;
    while (y > state.cursor_y + 1) : (y -= 1) {
        @memcpy(state.lines[y][0..MAX_COLS], state.lines[y - 1][0..MAX_COLS]);
        state.line_lens[y] = state.line_lens[y - 1];
    }

    const line = state.lines[state.cursor_y];
    const split_pos = state.cursor_x;
    const old_len = state.line_lens[state.cursor_y];
    const new_len = old_len - split_pos;

    @memcpy(state.lines[state.cursor_y + 1][0..new_len], line[split_pos..old_len]);
    state.line_lens[state.cursor_y + 1] = new_len;
    state.line_lens[state.cursor_y] = split_pos;

    state.num_lines += 1;
    state.cursor_y += 1;
    state.cursor_x = 0;
}

fn showMessage(out: *ConOut, msg: []const u8, state: *EditorState) void {
    _ = out.setCursorPosition(0, 23);
    print(out, msg);
    // Wait for any key
    const in = uefi.system_table.con_in orelse return;
    var key: ConIn.Key.Input = undefined;
    _ = in.readKeyStroke(&key);
    _ = out.clearScreen();
    drawEditor(out, state);
}

// ============================================
// FILE SYSTEM
// ============================================

fn getInputEx() !*InputEx {
    const bs = uefi.system_table.boot_services.?;
    var input_ex: *InputEx = undefined;

    const in_handle = uefi.system_table.console_in_handle orelse return error.NoProtocol;
    const status = bs.openProtocol(in_handle, &InputEx.guid, @ptrCast(&input_ex), uefi.handle, null, .{ .by_handle_protocol = true });

    if (status != .Success) return error.NoProtocol;
    return input_ex;
}

fn readKeyRaw(input_ex: *InputEx) !InputEx.Key {
    var key: InputEx.Key = undefined;
    var index: usize = undefined;
    const events = [_]uefi.Event{input_ex.wait_for_key_ex};
    const wait_status = uefi.system_table.boot_services.?.waitForEvent(1, &events, &index);
    if (wait_status != .Success) return error.WaitFailed;

    const status = input_ex.readKeyStrokeEx(&key);
    if (status != .Success) return error.ReadFailed;
    return key;
}

fn loadFile(state: *EditorState, filename: []const u8) !void {
    var file_buffer: [MAX_FILE_SIZE]u8 = undefined;
    const file_data = readFileFromDisk(filename, &file_buffer) catch {
        return;
    };
    if (file_data.len == 0) return;

    var line_idx: usize = 0;
    var col: usize = 0;

    for (file_data) |c| {
        if (c == '\n') {
            state.line_lens[line_idx] = col;
            line_idx += 1;
            if (line_idx >= MAX_LINES) break;
            col = 0;
        } else if (c != '\r' and col < MAX_COLS) {
            state.lines[line_idx][col] = c;
            col += 1;
        }
    }

    if (col > 0 and line_idx < MAX_LINES) {
        state.line_lens[line_idx] = col;
        line_idx += 1;
    }

    state.num_lines = @max(1, line_idx);
}

fn saveFile(state: *EditorState, filename: []const u8) !void {
    var size: usize = 0;
    for (0..state.num_lines) |i| {
        size += state.line_lens[i] + 1;
    }

    var buffer: [MAX_FILE_SIZE]u8 = undefined;
    if (size > buffer.len) return error.FileTooBig;

    var pos: usize = 0;
    for (0..state.num_lines) |i| {
        const len = state.line_lens[i];
        @memcpy(buffer[pos..][0..len], state.lines[i][0..len]);
        pos += len;
        buffer[pos] = '\n';
        pos += 1;
    }

    try writeFileToDisk(filename, buffer[0..pos]);
}

fn listFiles(out: *ConOut, dir_path: ?[]const u8) !void {
    const bs = uefi.system_table.boot_services.?;

    var loaded_image: *uefi.protocol.LoadedImage = undefined;
    var status = bs.openProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, @ptrCast(&loaded_image), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return error.NoLoadedImage;

    var fs: *SimpleFileSystem = undefined;
    status = bs.openProtocol(loaded_image.device_handle.?, &SimpleFileSystem.guid, @ptrCast(&fs), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return error.NoFileSystem;

    var root: *FileProtocol = undefined;
    status = fs.openVolume(&root);
    if (status != .Success) return error.OpenVolumeFailed;
    defer _ = root.close();

    var dir = root;
    if (dir_path) |path| {
        if (path.len > 1) { // Skip if just "/"
            var path_buf: [256]u16 = undefined;
            const file_path = try utf8ToUefiPath(path, &path_buf);
            status = root.open(&dir, file_path, 1, 0);
            if (status != .Success) return error.OpenFailed;
        }
    }

    var buf: [2048]u8 = undefined;
    var size: usize = buf.len;

    while (true) {
        size = buf.len;
        status = dir.read(&size, &buf);
        if (status != .Success or size == 0) break;

        var pos: usize = 0;
        while (pos < size) {
            const info = @as(*FileInfo, @ptrCast(@alignCast(&buf[pos])));
            const name = info.getFileName();

            if (info.size == 0) break;

            var name_buf: [256]u8 = undefined;
            var name_len: usize = 0;
            var i: usize = 0;
            while (name[i] != 0 and name_len < name_buf.len - 1) : (i += 1) {
                name_buf[name_len] = @intCast(name[i]);
                name_len += 1;
            }
            name_buf[name_len] = 0;

            if (info.attribute & FileInfo.efi_file_directory != 0) {
                print(out, name_buf[0..name_len]);
                print(out, "/\n");
            } else {
                print(out, name_buf[0..name_len]);
                print(out, "\n");
            }

            pos += @intCast(info.size);
        }
    }
}

fn changeDirectory(path: []const u8) bool {
    const bs = uefi.system_table.boot_services.?;

    var loaded_image: *uefi.protocol.LoadedImage = undefined;
    var status = bs.openProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, @ptrCast(&loaded_image), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return false;

    var fs: *SimpleFileSystem = undefined;
    status = bs.openProtocol(loaded_image.device_handle.?, &SimpleFileSystem.guid, @ptrCast(&fs), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return false;

    var root: *FileProtocol = undefined;
    status = fs.openVolume(&root);
    if (status != .Success) return false;
    defer _ = root.close();

    var dir: *FileProtocol = undefined;

    if (path.len > 1) {
        var path_buf: [256]u16 = undefined;
        const file_path = utf8ToUefiPath(path, &path_buf) catch return false;
        status = root.open(&dir, file_path, 1, 0);
        if (status != .Success) return false;
        _ = dir.close();
    }

    current_dir_len = path.len;
    @memcpy(current_dir[0..path.len], path);
    return true;
}

fn readFileFromDisk(filename: []const u8, buffer: []u8) ![]u8 {
    const bs = uefi.system_table.boot_services.?;

    var loaded_image: *uefi.protocol.LoadedImage = undefined;
    var status = bs.openProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, @ptrCast(&loaded_image), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return error.NoLoadedImage;

    var fs: *SimpleFileSystem = undefined;
    status = bs.openProtocol(loaded_image.device_handle.?, &SimpleFileSystem.guid, @ptrCast(&fs), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return error.NoFileSystem;

    var root: *FileProtocol = undefined;
    status = fs.openVolume(&root);
    if (status != .Success) return error.OpenVolumeFailed;
    defer _ = root.close();

    var path_buf: [256]u16 = undefined;
    const file_path = try utf8ToUefiPath(filename, &path_buf);

    var file: *FileProtocol = undefined;
    status = root.open(&file, file_path, 1, 0);
    if (status != .Success) return error.FileNotFound;
    defer _ = file.close();

    var info_buf: [256]u8 = undefined;
    var info_size: usize = info_buf.len;
    status = file.getInfo(&file_info_guid, &info_size, &info_buf);
    if (status != .Success) return error.GetInfoFailed;

    const info = @as(*FileInfo, @ptrCast(@alignCast(&info_buf)));
    const file_size = info.file_size;

    if (file_size > buffer.len) return error.FileTooBig;

    var read_size: usize = file_size;
    status = file.read(&read_size, buffer.ptr);
    if (status != .Success) return error.ReadFailed;

    return buffer[0..read_size];
}

fn writeFileToDisk(filename: []const u8, data: []const u8) !void {
    const bs = uefi.system_table.boot_services.?;

    var loaded_image: *uefi.protocol.LoadedImage = undefined;
    var status = bs.openProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, @ptrCast(&loaded_image), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return error.NoLoadedImage;

    var fs: *SimpleFileSystem = undefined;
    status = bs.openProtocol(loaded_image.device_handle.?, &SimpleFileSystem.guid, @ptrCast(&fs), uefi.handle, null, .{ .by_handle_protocol = true });
    if (status != .Success) return error.NoFileSystem;

    var root: *FileProtocol = undefined;
    status = fs.openVolume(&root);
    if (status != .Success) return error.OpenVolumeFailed;
    defer _ = root.close();

    var path_buf: [256]u16 = undefined;
    const file_path = try utf8ToUefiPath(filename, &path_buf);

    var file: *FileProtocol = undefined;
    status = root.open(&file, file_path, FileProtocol.efi_file_mode_read | FileProtocol.efi_file_mode_write | FileProtocol.efi_file_mode_create, 0);
    if (status != .Success) return error.CreateFailed;
    defer _ = file.close();

    var write_size: usize = data.len;
    status = file.write(&write_size, data.ptr);
    if (status != .Success) return error.WriteFailed;

    status = file.flush();
    if (status != .Success) return error.FlushFailed;
}

fn utf8ToUefiPath(utf8: []const u8, buf: []u16) ![:0]const u16 {
    if (utf8.len > buf.len - 1) return error.NameTooLong;

    for (utf8, 0..) |c, i| {
        buf[i] = c;
    }
    buf[utf8.len] = 0;

    return buf[0..utf8.len :0];
}

// ============================================
// KEYBOARD TEST
// ============================================

fn testKeyboard(out: *ConOut) !void {
    const input_ex = try getInputEx();

    var last_unicode: u16 = 0;
    var last_scan_code: u16 = 0;

    while (true) {
        _ = out.setCursorPosition(0, 0);

        print(out, "=== Keyboard Test ===\n");
        print(out, "Press any key (ESC to exit)\n\n");
        print(out, "Last Key:\n");
        print(out, "  Unicode: ");

        var buf: [16]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{}", .{last_unicode}) catch "-";
        print(out, str);

        print(out, "\n  ScanCode: 0x");
        const sc_str = std.fmt.bufPrint(&buf, "{x}", .{last_scan_code}) catch "-";
        print(out, sc_str);
        print(out, " (");

        // Show key name based on scan code
        const key_name: []const u8 = switch (last_scan_code) {
            0x04 => "A",
            0x05 => "B",
            0x06 => "C",
            0x07 => "D",
            0x08 => "E",
            0x09 => "F",
            0x0A => "G",
            0x0B => "H",
            0x0C => "I",
            0x0D => "J",
            0x0E => "K",
            0x0F => "L",
            0x10 => "M",
            0x11 => "N",
            0x12 => "O",
            0x13 => "P",
            0x14 => "Q",
            0x15 => "R",
            0x16 => "S",
            0x17 => "DOWN",
            0x18 => "UP",
            0x19 => "LEFT",
            0x1A => "RIGHT",
            0x1B => "TAB",
            0x1C => "ENTER",
            0x1E => "1",
            0x1F => "2",
            0x20 => "3",
            0x21 => "4",
            0x22 => "5",
            0x23 => "6",
            0x24 => "7",
            0x25 => "8",
            0x26 => "9",
            0x27 => "0",
            0x2D => "-",
            0x2E => "=",
            0x2F => "BS",
            0x32 => "\\",
            0x33 => ";",
            0x34 => "'",
            0x35 => "`",
            0x39 => "SPACE",
            0x4A => "HOME",
            0x4B => "PGUP",
            0x4C => "DEL",
            0x4D => "END",
            0x4E => "PGDN",
            0x50 => "F1",
            0x51 => "F2",
            0x52 => "F3",
            0x53 => "F4",
            0x54 => "F5",
            0x55 => "F6",
            0x56 => "F7",
            0x57 => "F8",
            0x58 => "F9",
            0x59 => "F10",
            0x5A => "F11",
            0x5B => "F12",
            0x76 => "ESC",
            else => "?",
        };
        print(out, key_name);
        print(out, ")\n");

        const key = try readKeyRaw(input_ex);
        last_unicode = key.input.unicode_char;
        last_scan_code = key.input.scan_code;

        if (key.input.scan_code == 0x76) { // ESC
            return;
        }
    }
}

// ============================================
// SNAKE GAME
// ============================================

fn runSnake(out: *ConOut, in: *ConIn) !void {
    const width = 20;
    const height = 10;

    var snake_x: [64]i32 = undefined;
    var snake_y: [64]i32 = undefined;
    var length: usize = 3;

    snake_x[0] = width / 2;
    snake_y[0] = height / 2;
    snake_x[1] = snake_x[0] - 1;
    snake_y[1] = snake_y[0];
    snake_x[2] = snake_x[1] - 1;
    snake_y[2] = snake_y[1];

    var dir_x: i32 = 1;
    var dir_y: i32 = 0;

    var food_x: i32 = 3;
    var food_y: i32 = 3;

    if (out.clearScreen() != .Success) return;

    while (true) {
        drawSnake(out, snake_x[0..length], snake_y[0..length], width, height, food_x, food_y);

        var index: usize = undefined;
        const events = [_]uefi.Event{in.wait_for_key};
        const wait_status = uefi.system_table.boot_services.?.waitForEvent(1, &events, &index);
        if (wait_status != .Success) return error.WaitFailed;

        var key: ConIn.Key.Input = undefined;
        const key_status = in.readKeyStroke(&key);
        if (key_status != .Success) return error.ReadFailed;

        if (key.unicode_char == 'c' or key.unicode_char == 'C') {
            _ = out.clearScreen();
            return;
        }

        switch (key.unicode_char) {
            'w', 'W' => {
                dir_x = 0;
                dir_y = -1;
            },
            's', 'S' => {
                dir_x = 0;
                dir_y = 1;
            },
            'a', 'A' => {
                dir_x = -1;
                dir_y = 0;
            },
            'd', 'D' => {
                dir_x = 1;
                dir_y = 0;
            },
            else => {},
        }

        var i: usize = length - 1;
        while (i > 0) : (i -= 1) {
            snake_x[i] = snake_x[i - 1];
            snake_y[i] = snake_y[i - 1];
        }

        snake_x[0] += dir_x;
        snake_y[0] += dir_y;

        if (snake_x[0] < 0) snake_x[0] = width - 1;
        if (snake_y[0] < 0) snake_y[0] = height - 1;
        if (snake_x[0] >= width) snake_x[0] = 0;
        if (snake_y[0] >= height) snake_y[0] = 0;

        if (snake_x[0] == food_x and snake_y[0] == food_y and length < snake_x.len) {
            length += 1;
            food_x = @mod(food_x + 7, width);
            food_y = @mod(food_y + 5, height);
        }
    }
}

fn drawSnake(out: *ConOut, xs: []const i32, ys: []const i32, w: i32, h: i32, food_x: i32, food_y: i32) void {
    if (out.clearScreen() != .Success) return;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            var drawn = false;

            for (xs, 0..) |sx, i| {
                if (sx == x and ys[i] == y) {
                    print(out, "#");
                    drawn = true;
                    break;
                }
            }

            if (!drawn and x == food_x and y == food_y) {
                print(out, "*");
                drawn = true;
            }

            if (!drawn) print(out, ".");
        }
        print(out, "\n");
    }

    print(out, "WASD to move, C to exit\n");
}

// ============================================
// UTILITIES
// ============================================

fn readLine(in: *ConIn, out: *ConOut, buffer: []u8) !usize {
    var index: usize = 0;

    while (true) {
        var event_index: usize = undefined;
        const events = [_]uefi.Event{in.wait_for_key};
        const wait_status = uefi.system_table.boot_services.?.waitForEvent(1, &events, &event_index);
        if (wait_status != .Success) return error.WaitFailed;

        var key: ConIn.Key.Input = undefined;
        const key_status = in.readKeyStroke(&key);
        if (key_status != .Success) return error.ReadFailed;

        switch (key.unicode_char) {
            '\r' => {
                print(out, "\n");
                return index;
            },
            '\x08' => {
                if (index > 0) {
                    index -= 1;
                    print(out, "\x08 \x08");
                }
            },
            else => |c| {
                if (c >= 32 and c < 127 and index + 1 < buffer.len) {
                    buffer[index] = @intCast(c);
                    index += 1;

                    var utf16: [2:0]u16 = .{ c, 0 };
                    _ = out.outputString(&utf16);
                }
            },
        }
    }
}

fn print(out: *ConOut, s: []const u8) void {
    var utf16_buf: [512]u16 = undefined;
    var j: usize = 0;

    var i: usize = 0;
    while (i < s.len and j + 1 < utf16_buf.len) {
        const c = s[i];

        if (c == '\n') {
            utf16_buf[j] = '\r';
            utf16_buf[j + 1] = '\n';
            j += 2;
            i += 1;
        } else if (c < 0x80) {
            utf16_buf[j] = c;
            j += 1;
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
                utf16_buf[j] = '?';
                j += 1;
                i += 1;
                continue;
            };

            if (i + seq_len > s.len) {
                utf16_buf[j] = '?';
                j += 1;
                i += 1;
                continue;
            }

            const codepoint = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                utf16_buf[j] = '?';
                j += 1;
                i += 1;
                continue;
            };

            if (codepoint < 0x10000) {
                utf16_buf[j] = @intCast(codepoint);
                j += 1;
            } else {
                if (j + 2 >= utf16_buf.len) break;
                const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
                const low = @as(u16, @intCast((codepoint - 0x10000) & 0x3FF)) + 0xDC00;
                utf16_buf[j] = high;
                utf16_buf[j + 1] = low;
                j += 2;
            }
            i += seq_len;
        }
    }

    utf16_buf[j] = 0;
    _ = out.outputString(utf16_buf[0..j :0]);
}
