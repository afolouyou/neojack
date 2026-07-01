const std = @import("std");
const shm = @import("../shm/layouts.zig");
const JACK_DEFAULT_AUDIO_TYPE = shm.JACK_DEFAULT_AUDIO_TYPE;

pub fn isMidiPort(port_type: []const u8) bool {
    return std.mem.eql(u8, port_type, shm.JACK_DEFAULT_MIDI_TYPE);
}

pub fn midiBufferInit(buf: []u8, buffer_size: usize, nframes: u32) void {
    @memset(buf[0..@min(buf.len, buffer_size)], 0);
    const mb: *shm.JackMidiBuffer = @ptrCast(@alignCast(buf.ptr));
    mb.magic = shm.JACK_MIDI_MAGIC;
    mb.buffer_size = @intCast(buffer_size);
    mb.nframes = nframes;
    mb.write_pos = @intCast(buffer_size);
    mb.event_count = 0;
    mb.lost_events = 0;
}

pub fn midiEventCount(buf: []u8) u32 {
    const mb: *shm.JackMidiBuffer = @ptrCast(@alignCast(buf.ptr));
    return mb.event_count;
}

pub fn midiEventGet(buf: []u8, index: u32, event: *shm.jack_midi_event_t) bool {
    const mb: *shm.JackMidiBuffer = @ptrCast(@alignCast(buf.ptr));
    if (index >= mb.event_count) return false;

    const me = &mb.events[@as(usize, @intCast(index))];
    event.time = me.time;
    event.size = @as(usize, @intCast(@max(me.size, 0)));

    if (me.size <= shm.JackMidiEvent.INLINE_SIZE_MAX) {
        event.buffer = &me.data.inline_data;
    } else {
        const data_ptr = @as([*]u8, @ptrCast(mb)) + @as(usize, @intCast(me.data.offset));
        event.buffer = data_ptr;
    }
    return true;
}

pub fn midiEventWrite(buf: []u8, time: u32, data: []const u8) bool {
    const mb: *shm.JackMidiBuffer = @ptrCast(@alignCast(buf.ptr));
    const data_size = @as(i32, @intCast(data.len));

    if (data_size <= 0) return false;

    if (mb.event_count >= (shm.JACK_MIDI_BUFFER_SIZE - @sizeOf(shm.JackMidiBuffer)) / @sizeOf(shm.JackMidiEvent)) {
        mb.lost_events += 1;
        return false;
    }

    const me = &mb.events[@as(usize, @intCast(mb.event_count))];
    me.time = time;
    me.size = data_size;

    if (data_size <= 4) {
        @memcpy(me.data.inline_data[0..@as(usize, @intCast(data_size))], data);
    } else {
        const new_write_pos = mb.write_pos - data_size;
        if (new_write_pos <= @as(i32, @intCast(@sizeOf(shm.JackMidiBuffer) + mb.event_count * @sizeOf(shm.JackMidiEvent)))) {
            mb.lost_events += 1;
            return false;
        }
        me.data.offset = new_write_pos;
        const dest = @as([*]u8, @ptrCast(mb)) + @as(usize, @intCast(new_write_pos));
        @memcpy(dest[0..data.len], data);
        mb.write_pos = new_write_pos;
    }

    mb.event_count += 1;
    return true;
}

pub fn midiClearBuffer(buf: []u8) void {
    const mb: *shm.JackMidiBuffer = @ptrCast(@alignCast(buf.ptr));
    mb.write_pos = mb.buffer_size;
    mb.event_count = 0;
    mb.lost_events = 0;
}
