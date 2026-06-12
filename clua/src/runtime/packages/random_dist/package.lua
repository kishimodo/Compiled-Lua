return {
    name        = "random_dist",
    version     = "1.0",
    description = "Probability distributions: sampling + PDF/CDF/quantile + mean/variance. Distribution-object API (d = random_dist.normal(0,1); d:sample(); d:pdf(x); d:cdf(x); d:quantile(p)). Supports uniform, normal, exponential, gamma, beta, chi_squared, student_t, f, lognormal, weibull, pareto, cauchy, poisson, binomial, geometric, bernoulli. Internal seedable xoshiro256** RNG built on Lua 5.4 native bitwise ops; create_rng(seed) returns an instance.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["random_dist"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
