const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.clock);

const config = @import("config.zig");

const clock_offset_tolerance: u64 = config.clock_offset_tolerance_max_ms * std.time.ns_per_ms;
const epoch_max: u64 = config.clock_epoch_max_ms * std.time.ns_per_ms;
const window_min: u64 = config.clock_synchronization_window_min_ms * std.time.ns_per_ms;
const window_max: u64 = config.clock_synchronization_window_max_ms * std.time.ns_per_ms;

const Marzullo = @import("marzullo.zig").Marzullo;

const Sample = struct {
    /// The relative difference between our wall clock reading and that of the remote clock source.
    clock_offset: i64,
    one_way_delay: u64,
};

const Epoch = struct {
    const Self = @This();

    /// The best clock offset sample per remote clock source (with minimum one way delay) collected
    /// over the course of a window period of several seconds.
    sources: []?Sample,

    /// The monotonic clock timestamp when this epoch began. We use this to measure elapsed time.
    monotonic: u64,

    /// The wall clock timestamp when this epoch began. We add the elapsed monotonic time to this
    /// plus the synchronized clock offset to arrive at a synchronized realtime timestamp. We
    /// capture this realtime when starting the epoch, before we take any samples, to guard against
    /// any jumps in the system's realtime clock from impacting our measurements.
    realtime: i64,

    /// Once we have enough source clock offset samples in agreement, the epoch is synchronized.
    /// We then have lower and upper bounds on the true cluster time, and can install this epoch for
    /// subsequent clock readings. This epoch is then valid for several seconds, while clock drift
    /// has not had enough time to accumulate into any significant clock skew, and while we collect
    /// samples for the next epoch to refresh and replace this one.
    synchronized: ?Marzullo.Interval,

    /// A guard to prevent synchronizing too often without having learned any new samples.
    learned: bool = false,

    fn elapsed(self: *Self, clock: *Clock) u64 {
        return clock.monotonic() - self.monotonic;
    }

    fn reset(self: *Self, clock: *Clock) void {
        std.mem.set(?Sample, self.sources, null);
        // A replica always has zero clock offset and network delay to its own system time reading:
        self.sources[clock.replica] = Sample{
            .clock_offset = 0,
            .one_way_delay = 0,
        };
        self.monotonic = clock.monotonic();
        self.realtime = clock.realtime();
        self.synchronized = null;
        self.learned = false;
    }
};

pub const Clock = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    /// The index of the replica using this clock to provide synchronized time.
    replica: u8,

    /// The underlying time source for this clock (system time or deterministic time).
    /// TODO Replace this with SystemTime in production, or DeterministicTime in testing.
    time: *DeterministicTime,

    /// An epoch from which the clock can read synchronized clock timestamps within safe bounds.
    /// At least `config.clock_synchronization_window_min_ms` is needed for this to be ready to use.
    epoch: Epoch,

    /// The next epoch (collecting samples and being synchronized) to replace the current epoch.
    window: Epoch,

    /// A static allocation to convert window samples into tuple bounds for Marzullo's algorithm.
    marzullo_tuples: []Marzullo.Tuple,

    pub fn init(
        allocator: *std.mem.Allocator,
        /// The size of the cluster, i.e. the number of clock sources (including this replica).
        replica_count: u8,
        replica: u8,
        time: *DeterministicTime,
    ) !Clock {
        assert(replica_count > 0);
        assert(replica < replica_count);

        var epoch: Epoch = undefined;
        epoch.sources = try allocator.alloc(?Sample, replica_count);
        errdefer allocator.free(epoch.sources);

        var window: Epoch = undefined;
        window.sources = try allocator.alloc(?Sample, replica_count);
        errdefer allocator.free(window.sources);

        // There are two Marzullo tuple bounds (lower and upper) per source clock offset sample:
        var marzullo_tuples = try allocator.alloc(Marzullo.Tuple, replica_count * 2);
        errdefer allocator.free(marzullo_tuples);

        var self = Clock{
            .allocator = allocator,
            .replica = replica,
            .time = time,
            .epoch = epoch,
            .window = window,
            .marzullo_tuples = marzullo_tuples,
        };

        // Reset the current epoch to be unsynchronized,
        self.epoch.reset(&self);
        // and open a new epoch window to start collecting samples...
        self.window.reset(&self);

        return self;
    }

    /// Called by `Replica.on_pong()` with:
    /// * the index of the `replica` that has replied to our ping with a pong,
    /// * our monotonic timestamp `m0` embedded in the ping we sent, carried over into this pong,
    /// * the remote replica's `realtime()` timestamp `t1`, and
    /// * our monotonic timestamp `m2` as captured by our `Replica.on_pong()` handler.
    pub fn learn(self: *Self, replica: u8, m0: u64, t1: i64, m2: u64) void {
        // A network routing fault must have replayed one of our outbound messages back against us:
        if (replica == self.replica) return;

        // Our m0 and m2 readings should always be monotonically increasing.
        // This condition should never be true. Reject this as a bad sample:
        if (m0 >= m2) return;

        // We may receive delayed packets after a reboot, in which case m0/m2 will also be invalid:
        // TODO Add an identifier for this epoch to pings/pongs to bind them to the current window.
        if (m0 < self.window.monotonic) return;
        if (m2 < self.window.monotonic) return;
        const elapsed: u64 = m2 - self.window.monotonic;
        if (elapsed > window_max) return;

        const round_trip_time: u64 = m2 - m0;
        const one_way_delay: u64 = round_trip_time / 2;
        const t2: i64 = self.window.realtime + @intCast(i64, elapsed);
        const clock_offset: i64 = t1 + @intCast(i64, one_way_delay) - t2;

        log.debug("learn: replica={} m0={} t1={} m2={} t2={} one_way_delay={} clock_offset={}", .{
            replica,
            m0,
            t1,
            m2,
            t2,
            one_way_delay,
            clock_offset,
        });

        // TODO Correct asymmetric error when we can see it's there.
        // "A System for Clock Synchronization in an Internet of Things" Section 4.2

        // The less network delay, the more likely we have an accurante clock offset measurement:
        self.window.sources[replica] = minimum_one_way_delay(self.window.sources[replica], Sample{
            .clock_offset = clock_offset,
            .one_way_delay = one_way_delay,
        });

        // We decouple calls to `synchronize()` so that it's not triggered by these network events.
        // Otherwise, excessive duplicate network packets would burn the CPU.
        self.window.learned = true;
    }

    /// Called by `Replica.on_ping_timeout()` to provide `m0` when we decide to send a ping.
    /// Called by `Replica.on_pong()` to provide `m2` when we receive a pong.
    pub fn monotonic(self: *Self) u64 {
        return self.time.monotonic();
    }

    /// Called by `Replica.on_ping()` when responding to a ping with a pong.
    /// We use synchronized time if possible, so that the cluster remembers true time as a whole.
    /// Otherwise, if one or two replicas with accurate clocks fail we may be unable to synchronize.
    /// We fall back to offering our wall clock reading if we do not yet have any synchronized time.
    /// This should never be used by the state machine, only for measuring clock offsets.
    pub fn realtime(self: *Self) i64 {
        return self.realtime_synchronized() orelse self.time.realtime();
    }

    /// Called by `StateMachine.prepare_timestamp()` when the leader wants to timestamp a batch.
    /// If the leader's clock is not synchronized with the cluster, it must wait until it is.
    /// Returns the system time clamped to be within our synchronized lower and upper bounds.
    /// This is complementary to NTP and allows clusters with very accurate time to make use of it,
    /// while providing guard rails for when NTP is partitioned or unable to correct quickly enough.
    pub fn realtime_synchronized(self: *Self) ?i64 {
        if (self.epoch.synchronized) |interval| {
            const elapsed = @intCast(i64, self.epoch.elapsed(self));
            return std.math.clamp(
                self.time.realtime(),
                self.epoch.realtime + elapsed + interval.lower_bound,
                self.epoch.realtime + elapsed + interval.upper_bound,
            );
        } else {
            return null;
        }
    }

    pub fn tick(self: *Self) void {
        self.time.tick();
        self.synchronize();

        // Expire the current epoch if successive windows failed to synchronize:
        // Gradual clock drift prevents us from using an epoch for more than a few tens of seconds.
        if (self.epoch.synchronized != null and self.epoch.elapsed(self) >= epoch_max) {
            log.alert("no agreement on cluster time (partitioned or too many clock faults)", .{});
            self.epoch.reset(self);
        }
    }

    fn synchronize(self: *Self) void {
        assert(self.window.synchronized == null);

        // Avoid polling the monotonic time if we know we have no new samples to synchronize on:
        if (!self.window.learned) return;

        // Wait until the window has enough accurate samples:
        const elapsed = self.window.elapsed(self);
        if (elapsed < window_min) return;
        if (elapsed >= window_max) {
            // We took too long to synchronize the window, expire stale samples...
            log.crit("expiring synchronization window after {}", .{std.fmt.fmtDuration(elapsed)});
            self.window.reset(self);
            return;
        }

        // Starting with the most clock offset tolerance, while we have a majority, find the best
        // smallest interval with the least clock offset tolerance, reducing tolerance at each step:
        var tolerance: u64 = clock_offset_tolerance;
        var terminate = false;
        var rounds: usize = 0;
        // Do at least one round if tolerance=0 and cap the number of rounds to avoid runaway loops.
        while (!terminate and rounds < 64) : (tolerance /= 2) {
            if (tolerance == 0) terminate = true;
            rounds += 1;

            var interval = Marzullo.smallest_interval(self.window_tuples(tolerance));
            const majority = interval.sources_true > @divTrunc(self.window.sources.len, 2);
            if (!majority) break;

            // The new interval may reduce the number of `sources_true` while also decreasing error.
            // In other words, provided we maintain a majority, we prefer tighter tolerance bounds.
            self.window.synchronized = interval;
        }

        // Do not reset `learned` any earlier than this (before we have attempted to synchronize).
        self.window.learned = false;

        // Wait for more accurate samples or until we timeout the window for lack of majority:
        if (self.window.synchronized == null) return;

        var old_epoch_synchronized = self.epoch.synchronized;

        var new_window = self.epoch;
        new_window.reset(self);
        self.epoch = self.window;
        self.window = new_window;

        self.after_synchronization(old_epoch_synchronized);
    }

    fn after_synchronization(self: *Self, old_epoch_synchronized: ?Marzullo.Interval) void {
        const new_interval = self.epoch.synchronized.?;

        log.info("synchronized: truechimers={}/{} clock_offset={}..{} accuracy={}", .{
            new_interval.sources_true,
            self.epoch.sources.len,
            fmtDurationSigned(new_interval.lower_bound),
            fmtDurationSigned(new_interval.upper_bound),
            fmtDurationSigned(new_interval.upper_bound - new_interval.lower_bound),
        });

        const elapsed = @intCast(i64, self.epoch.elapsed(self));
        const system = self.time.realtime();
        const lower = self.epoch.realtime + elapsed + new_interval.lower_bound;
        const upper = self.epoch.realtime + elapsed + new_interval.upper_bound;
        const cluster = std.math.clamp(system, lower, upper);

        if (system == cluster) {
            log.info("system time is within cluster time", .{});
        } else if (system < lower) {
            log.err("system time is {} behind, clamping system time to cluster time", .{
                fmtDurationSigned(lower - system),
            });
        } else {
            log.err("system time is {} ahead, clamping system time to cluster time", .{
                fmtDurationSigned(system - upper),
            });
        }

        if (old_epoch_synchronized) |old_interval| {
            const a = old_interval.upper_bound - old_interval.lower_bound;
            const b = new_interval.upper_bound - new_interval.lower_bound;
            if (b > a) {
                log.notice("clock sources required {} more tolerance to synchronize", .{
                    std.fmt.fmtDuration(@intCast(u64, b - a)),
                });
            }
        }
    }

    fn window_tuples(self: *Self, tolerance: u64) []Marzullo.Tuple {
        assert(self.window.sources[self.replica].?.clock_offset == 0);
        assert(self.window.sources[self.replica].?.one_way_delay == 0);
        var count: usize = 0;
        for (self.window.sources) |sampled, source| {
            if (sampled) |sample| {
                self.marzullo_tuples[count] = Marzullo.Tuple{
                    .source = @intCast(u8, source),
                    .offset = sample.clock_offset - @intCast(i64, sample.one_way_delay + tolerance),
                    .bound = .lower,
                };
                count += 1;
                self.marzullo_tuples[count] = Marzullo.Tuple{
                    .source = @intCast(u8, source),
                    .offset = sample.clock_offset + @intCast(i64, sample.one_way_delay + tolerance),
                    .bound = .upper,
                };
                count += 1;
            }
        }
        return self.marzullo_tuples[0..count];
    }

    fn minimum_one_way_delay(a: ?Sample, b: ?Sample) ?Sample {
        if (a == null) return b;
        if (b == null) return a;
        if (a.?.one_way_delay < b.?.one_way_delay) return a;
        // Choose B if B's one way delay is less or the same (we assume B is the newer sample):
        return b;
    }
};

pub const SystemTime = struct {
    const Self = @This();

    /// Hardware and/or software bugs can mean that the monotonic clock may regress.
    /// One example (of many): https://bugzilla.redhat.com/show_bug.cgi?id=448449
    /// We crash the process for safety if this ever happens, to protect against infinite loops.
    /// It's better to crash and come back with a valid monotonic clock than get stuck forever.
    monotonic_guard: u64 = 0,

    /// A timestamp to measure elapsed time, meaningful only on the same system, not across reboots.
    /// Always use a monotonic timestamp if the goal is to measure elapsed time.
    /// This clock is not affected by discontinuous jumps in the system time, for example if the
    /// system administrator manually changes the clock.
    pub fn monotonic(self: *Self) u64 {
        // The true monotonic clock on Linux is not in fact CLOCK_MONOTONIC:
        // CLOCK_MONOTONIC excludes elapsed time while the system is suspended (e.g. VM migration).
        // CLOCK_BOOTTIME is the same as CLOCK_MONOTONIC but includes elapsed time during a suspend.
        // For more detail and why CLOCK_MONOTONIC_RAW is even worse than CLOCK_MONOTONIC,
        // see https://github.com/ziglang/zig/pull/933#discussion_r656021295.
        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK_BOOTTIME, &ts) catch unreachable;
        const m = @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
        assert(m >= self.monotonic_guard);
        self.monotonic_guard = m;
        return m;
    }

    /// A timestamp to measure real (i.e. wall clock) time, meaningful across systems, and reboots.
    /// This clock is affected by discontinuous jumps in the system time.
    pub fn realtime(self: *Self) i64 {
        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK_REALTIME, &ts) catch unreachable;
        return @as(i64, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec;
    }

    pub fn tick(self: *Self) void {}
};

pub const DeterministicTime = struct {
    const Self = @This();

    /// The duration of a single tick in nanoseconds.
    resolution: u64,

    /// The number of ticks elapsed since initialization.
    ticks: u64 = 0,

    /// The instant in time chosen as the origin of this time source.
    epoch: i64 = 0,

    pub fn monotonic(self: *Self) u64 {
        return self.ticks * self.resolution;
    }

    pub fn realtime(self: *Self) i64 {
        return self.epoch + @intCast(i64, self.monotonic());
    }

    pub fn tick(self: *Self) void {
        self.ticks += 1;
    }
};

/// Return a Formatter for a signed number of nanoseconds according to magnitude:
/// [#y][#w][#d][#h][#m]#[.###][n|u|m]s
pub fn fmtDurationSigned(ns: i64) std.fmt.Formatter(formatDurationSigned) {
    return .{ .data = ns };
}

fn formatDurationSigned(
    ns: i64,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (ns < 0) {
        try writer.print("-{}", .{std.fmt.fmtDuration(@intCast(u64, -ns))});
    } else {
        try writer.print("{}", .{std.fmt.fmtDuration(@intCast(u64, ns))});
    }
}

// TODO Use tracing analysis to test a simulated trace, comparing against known values for accuracy.
fn test_simple() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const replica_count = 3;
    const replica = 0;
    var time = DeterministicTime{ .resolution = std.time.ns_per_s };

    var clock = try Clock.init(allocator, replica_count, replica, &time);

    const m0 = clock.window.monotonic;
    const t1 = clock.window.realtime + (50 + 500) * std.time.ns_per_ms;
    const m2 = clock.window.monotonic + 100 * std.time.ns_per_ms;

    clock.learn(1, m0, t1, m2);
    clock.learn(2, m0, t1, m2);

    var sync_again = true;

    while (clock.time.ticks < 100) {
        std.time.sleep(config.tick_ms * std.time.ns_per_ms);
        clock.tick();

        if (clock.realtime_synchronized() != null and sync_again) {
            sync_again = false;

            const bm0 = clock.window.monotonic;
            const bt1 = clock.window.realtime + (50 + 500) * std.time.ns_per_ms;
            const bm2 = clock.window.monotonic + 100 * std.time.ns_per_ms;

            clock.learn(1, bm0, bt1, bm2);
            clock.learn(2, bm0, bt1 + (500) * std.time.ns_per_ms, bm2);
        }
    }
}
