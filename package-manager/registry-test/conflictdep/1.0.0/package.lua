return {
  name = "conflictdep",
  version = "1.0.0",
  description = "requires leaf ^2.0.0 (to provoke a conflict with leaf ^1.0.0)",
  dependencies = { leaf = "^2.0.0" },
}
