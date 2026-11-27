// Runs backstage's OpenCode plugin (argv[2]) the way OpenCode does: setup() with a stand-in
// context, then its permission "evaluate" hook on a few shell commands. Prints "ok" or what failed.
const plugin = (await import(process.argv[2])).default
let hook
await plugin.setup({ permission: { hook: async (name, fn) => { if (name === "evaluate") hook = fn } } })
const decide = (action, resources) => {
  const event = { action, resources, effect: "allow" }
  hook(event)
  return event
}
const results = {
  id: typeof plugin.id === "string" && plugin.id.length > 0,
  hook: typeof hook === "function",
  allowsLs: decide("shell", ["ls -la"]).effect === "allow",
  deniesOpen: decide("shell", ["cd app", "open -a Safari"]).effect === "deny",
  explains: /backstage launch/.test(decide("shell", ["open -a Safari"]).message ?? ""),
  ignoresOtherActions: decide("read", ["open -a Safari"]).effect === "allow",
}
const failed = Object.entries(results).filter(([, v]) => !v).map(([k]) => k)
console.log(failed.length === 0 ? "ok" : "fail: " + failed.join(", "))
