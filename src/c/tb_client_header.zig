const std = @import("std");
const tb = @import("../tigerbeetle.zig");
const tb_client = @import("tb_client.zig");

const type_mappings = .{
    .{ tb.AccountFlags, "TB_ACCOUNT_FLAGS" },
    .{ tb.Account, "tb_account_t" },
    .{ tb.TransferFlags, "TB_TRANSFER_FLAGS" },
    .{ tb.Transfer, "tb_transfer_t" },
    .{ tb.CreateAccountResult, "TB_CREATE_ACCOUNT_RESULT" },
    .{ tb.CreateTransferResult, "TB_CREATE_TRANSFER_RESULT" },
    .{ tb.CreateAccountsResult, "tb_create_accounts_result_t" },
    .{ tb.CreateTransfersResult, "tb_create_transfers_result_t" },
    .{ tb_client.tb_operation_t, "TB_OPERATION" },
    .{ tb_client.tb_packet_status_t, "TB_PACKET_STATUS" },
    .{ tb_client.tb_packet_t, "tb_packet_t" },
    .{ tb_client.tb_packet_list_t, "tb_packet_list_t" },
    .{ tb_client.tb_client_t, "tb_client_t" },
    .{ tb_client.tb_status_t, "TB_STATUS" },
};

fn resolve_c_type(comptime Type: type) []const u8 {
    switch (@typeInfo(Type)) {
        .Array => |info| return resolve_c_type(info.child),
        .Enum => |info| return resolve_c_type(info.tag_type),
        .Struct => return resolve_c_type(std.meta.Int(.unsigned, @sizeOf(Type) * 8)),
        .Int => |info| {
            std.debug.assert(info.signedness == .unsigned);
            return switch (info.bits) {
                8 => "uint8_t",
                16 => "uint16_t",
                32 => "uint32_t",
                64 => "uint64_t",
                128 => "tb_uint128_t",
                else => @compileError("invalid int type"),
            };
        },
        .Optional => |info| switch (@typeInfo(info.child)) {
            .Pointer => return resolve_c_type(info.child),
            else => @compileError("Unsupported optional type: " ++ @typeName(Type)),
        },
        .Pointer => |info| {
            std.debug.assert(info.size != .Slice);
            std.debug.assert(!info.is_allowzero);

            inline for (type_mappings) |type_mapping| {
                const ZigType = type_mapping[0];
                const c_name = type_mapping[1];

                if (info.child == ZigType) {
                    const prefix = if (@typeInfo(ZigType) == .Struct) "struct " else "";
                    return prefix ++ c_name ++ "*";
                }
            }

            return resolve_c_type(info.child) ++ "*";
        },
        .Void, .Opaque => return "void",
        else => @compileError("Unhandled type: " ++ @typeName(Type)),
    }
}

fn to_uppercase(comptime input: []const u8) []const u8 {
    comptime var output: [input.len]u8 = undefined;
    inline for (output) |*char, i| {
        char.* = input[i];
        char.* -= 32 * @as(u8, @boolToInt(char.* >= 'a' and char.* <= 'z'));
    }
    return &output;
}

fn emit_enum(
    buffer: *std.ArrayList(u8),
    comptime type_info: anytype,
    comptime c_name: []const u8,
    comptime value_fmt: []const u8,
    comptime skip_fields: []const []const u8,
) !void {
    var suffix_pos = std.mem.lastIndexOf(u8, c_name, "_").?;
    if (std.mem.count(u8, c_name, "_") == 1) suffix_pos = c_name.len;

    try buffer.writer().print("typedef enum {s} {{\n", .{c_name});

    inline for (type_info.fields) |field, i| {
        comptime var skip = false;
        inline for (skip_fields) |sf| {
            skip = skip or comptime std.mem.eql(u8, sf, field.name);
        }

        if (!skip) {
            try buffer.writer().print("    {s}_{s} = " ++ value_fmt ++ ",\n", .{
                c_name[0..suffix_pos],
                to_uppercase(field.name),
                i,
            });
        }
    }

    try buffer.writer().print("}} {s};\n\n", .{c_name});
}

fn emit_struct(
    buffer: *std.ArrayList(u8),
    comptime type_info: anytype,
    comptime c_name: []const u8,
) !void {
    try buffer.writer().print("typedef struct {s} {{\n", .{c_name});

    inline for (type_info.fields) |field| {
        try buffer.writer().print("    {s} {s}", .{
            resolve_c_type(field.field_type),
            field.name,
        });

        switch (@typeInfo(field.field_type)) {
            .Array => |array| try buffer.writer().print("[{d}]", .{array.len}),
            else => {},
        }

        try buffer.writer().print(";\n", .{});
    }

    try buffer.writer().print("}} {s};\n\n", .{c_name});
}

pub fn main() !void {
    @setEvalBranchQuota(100_000);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer = std.ArrayList(u8).init(allocator);
    try buffer.writer().print(
        \\#ifndef TB_CLIENT_H
        \\#define TB_CLIENT_H
        \\ 
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\
        \\typedef __uint128_t tb_uint128_t;
        \\
        \\
    , .{});

    // Emit C type declarations.
    inline for (type_mappings) |type_mapping| {
        const ZigType = type_mapping[0];
        const c_name = type_mapping[1];

        switch (@typeInfo(ZigType)) {
            .Struct => |info| switch (info.layout) {
                .Auto => @compileError("Invalid C struct type: " ++ @typeName(ZigType)),
                .Packed => try emit_enum(&buffer, info, c_name, "1 << {d}", &.{"padding"}),
                .Extern => try emit_struct(&buffer, info, c_name),
            },
            .Enum => |info| {
                comptime var skip: []const []const u8 = &.{};
                if (ZigType == tb_client.tb_operation_t) {
                    skip = &.{ "reserved", "root", "register" };
                }

                try emit_enum(&buffer, info, c_name, "{d}", skip);
            },
            else => try buffer.writer().print("typedef {s} {s}; \n\n", .{
                resolve_c_type(ZigType),
                c_name,
            }),
        }
    }

    // Emit C function declarations.
    // TODO: use `std.meta.declaractions` and generate with pub + export functions.
    // Zig 0.9.1 has `decl.data.Fn.arg_names` but it's currently/incorrectly a zero-sized slice.
    try buffer.writer().print(
        \\TB_STATUS tb_client_init(
        \\    tb_client_t* out_client,
        \\    struct tb_packet_list_t* out_packets,
        \\    uint32_t cluster_id,
        \\    const char* address_ptr,
        \\    uint32_t address_len,
        \\    uint32_t packets_count,
        \\    uintptr_t on_completion_ctx,
        \\    void (*on_completion_fn)(uintptr_t, tb_client_t, tb_packet_t*, const uint8_t*, uint32_t)
        \\);
        \\
        \\TB_STATUS tb_client_init_echo(
        \\    tb_client_t* out_client,
        \\    struct tb_packet_list_t* out_packets,
        \\    uint32_t cluster_id,
        \\    const char* address_ptr,
        \\    uint32_t address_len,
        \\    uint32_t packets_count,
        \\    uintptr_t on_completion_ctx,
        \\    void (*on_completion_fn)(uintptr_t, tb_client_t, tb_packet_t*, const uint8_t*, uint32_t)
        \\);
        \\
        \\void tb_client_submit(
        \\    tb_client_t client,
        \\    struct tb_packet_list_t* packets
        \\);
        \\
        \\void tb_client_deinit(
        \\    tb_client_t client
        \\);
        \\
        \\
    , .{});

    try buffer.writer().print("#endif // TB_CLIENT_H\n\n", .{});
    try std.fs.cwd().writeFile("src/c/tb_client.h", buffer.items);
}
