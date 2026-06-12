return {
    name        = "stats",
    version     = "1.0",
    description = "Descriptive statistics + hypothesis tests. Mean, median, mode, variance, stdev, quantile, percentile, skewness, kurtosis, covariance, Pearson + Spearman correlation. Tests: one/two/paired t-test, chi-square goodness-of-fit, one-way ANOVA, Mann-Whitney U. Histogram. summary() one-call dashboard.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["stats"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
