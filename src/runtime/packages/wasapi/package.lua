-- WASAPI capture / playback. Shared mode by default, event-driven
-- so the callback fires when the device buffer wants more data.
return {
    name        = "wasapi",
    version     = "1.0",
    description = "WASAPI audio capture and playback wrapper. Talks IMMDeviceEnumerator / IMMDevice / IAudioClient / IAudioRenderClient / IAudioCaptureClient via FFI vtables. Event-driven mode (AUDCLNT_STREAMFLAGS_EVENTCALLBACK + SetEventHandle) keeps the host loop in step with the audio engine instead of polling. Device enumeration includes endpoint friendly names and default-device tagging.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["wasapi"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
