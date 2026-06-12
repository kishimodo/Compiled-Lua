return {
    name        = "fft",
    version     = "1.0",
    description = "Discrete Fourier transform. Cooley-Tukey radix-2 for power-of-two lengths, Bluestein's chirp-z transform for arbitrary N. Real or complex input. Plus dft() O(n^2) reference, ifft, magnitude, phase, convolve, and standard windows (rectangular, hann, hamming, blackman). Backed by the complex package.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["fft"] = "init.lua",
    },
    requires        = { "complex" },
    requires_native = {},
}
