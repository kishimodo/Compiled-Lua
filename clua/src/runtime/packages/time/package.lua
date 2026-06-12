return {
    name        = "time",
    version     = "2.0",
    description = "High-precision clocks (system + monotonic via QueryPerformanceCounter), calendar math, ISO 8601 parse/format, durations, and a datetime object with arithmetic operators. now(), monotonic(), monotonic_ns(), epoch_ms(), epoch_ns(), sleep(), sleep_until(). date(y,m,d) / time(h,m,s,ms?) / datetime(...) / from_epoch() / now_dt() build datetime objects with t.year/.month/.day/.hour/.minute/.second/.millisecond, t:weekday(), t:yearday(), t:format(pattern), t:to_iso8601({utc,fractional,with_offset}), t:to_utc(), t:to_local(), t:with_offset(). Arithmetic: t + duration -> t, t - t -> duration. duration(hms_string_or_table) with :days/:hours/:minutes/:seconds/:total_ms. add_days/months/years(t,n), start_of_day/month/year(t). UTC <-> local via Win32.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["time"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
