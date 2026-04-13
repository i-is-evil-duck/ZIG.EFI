const std = @import("std");
const uefi = std.os.uefi;

const ConOut = uefi.protocol.SimpleTextOutput;
const ConIn = uefi.protocol.SimpleTextInput;

pub fn main() uefi.Status {
    const st = uefi.system_table;
    const out = st.con_out.?;
    const in = st.con_in.?;

    out.reset(false) catch {};
    out.clearScreen() catch {};

    print(out, "\n");
    print(out, "Type 'help' for commands.\n\n");

    var buffer: [128]u8 = undefined;

    while (true) {
        print(out, "MiniOS> ");

        const len = readLine(in, out, &buffer);
        const line = buffer[0..len];

        handleCommand(line, out, in);
    }
}

fn handleCommand(cmd: []const u8, out: *ConOut, in: *ConIn) void {
    if (std.mem.eql(u8, cmd, "help")) {
        print(out,
            \\Commands:
            \\  help      - Show this message
            \\  clear     - Clear screen
            \\  shutdown  - Power off
            \\  echo TEXT - Print TEXT
            \\  snek      - Play snake (WASD, C to exit)
            \\
        );
    } else if (std.mem.eql(u8, cmd, "clear")) {
        out.clearScreen() catch {};
        out.setCursorPosition(0, 0) catch {};
    } else if (std.mem.eql(u8, cmd, "shutdown")) {
        uefi.system_table.runtime_services.resetSystem(.shutdown, .success, null);
        unreachable;
    } else if (std.mem.startsWith(u8, cmd, "echo ")) {
        print(out, cmd[5..]);
        print(out, "\n");
    } else if (std.mem.eql(u8, cmd, "snek")) {
        runSnake(out, in);
    } else if (cmd.len == 0) {
        // empty
    } else {
        print(out, "Unknown command. Type 'help'.\n");
    }
}

fn runSnake(out: *ConOut, in: *ConIn) void {
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

    out.clearScreen() catch {};

    while (true) {
        drawSnake(out, snake_x[0..length], snake_y[0..length], width, height, food_x, food_y);

        const events = [_]uefi.Event{ in.wait_for_key };
        _ = uefi.system_table.boot_services.?
            .waitForEvent(&events) catch unreachable;

        const key = in.readKeyStroke() catch unreachable;

        if (key.unicode_char == 'c' or key.unicode_char == 'C') {
            out.clearScreen() catch {};
            return;
        }

        switch (key.unicode_char) {
            'w', 'W' => { dir_x = 0; dir_y = -1; },
            's', 'S' => { dir_x = 0; dir_y = 1; },
            'a', 'A' => { dir_x = -1; dir_y = 0; },
            'd', 'D' => { dir_x = 1; dir_y = 0; },
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

        // food collision
        if (snake_x[0] == food_x and snake_y[0] == food_y and length < snake_x.len) {
            length += 1;
            food_x = @mod(food_x + 7, width);
            food_y = @mod(food_y + 5, height);
        }
    }
}

fn drawSnake(
    out: *ConOut,
    xs: []const i32,
    ys: []const i32,
    w: i32,
    h: i32,
    food_x: i32,
    food_y: i32,
) void {
    out.clearScreen() catch {};

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

fn readLine(in: *ConIn, out: *ConOut, buffer: []u8) usize {
    var index: usize = 0;

    while (true) {
        const events = [_]uefi.Event{ in.wait_for_key };
        _ = uefi.system_table.boot_services.?
            .waitForEvent(&events) catch unreachable;

        const key = in.readKeyStroke() catch unreachable;

        switch (key.unicode_char) {
            0x000D => {
                print(out, "\n");
                return index;
            },
            0x0008 => {
                if (index > 0) {
                    index -= 1;
                    print(out, "\x08 \x08");
                }
            },
            else => |c| {
                if (c >= 32 and c < 127 and index + 1 < buffer.len) {
                    buffer[index] = @intCast(c);
                    index += 1;

                    var utf16: [2]u16 = .{ c, 0 };
                    const s: [*:0]const u16 = utf16[0..1 :0];
                    _ = out.outputString(s) catch false;
                }
            },
        }
    }
}

fn print(out: *ConOut, s: []const u8) void {
    var utf16_buf: [512]u16 = undefined;
    var i: usize = 0;
    var j: usize = 0;

    while (i < s.len and j + 2 < utf16_buf.len) {
        if (s[i] == '\n') {
            utf16_buf[j] = '\r';
            utf16_buf[j + 1] = '\n';
            j += 2;
            i += 1;
        } else {
            utf16_buf[j] = s[i];
            j += 1;
            i += 1;
        }
    }

    utf16_buf[j] = 0;
    const slice: [*:0]const u16 = utf16_buf[0..j :0];
    _ = out.outputString(slice) catch false;
}
