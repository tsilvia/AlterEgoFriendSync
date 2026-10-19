// Runs every *_test.lua under tests/ (including subfolders) from the repo root,
// since tests use root-relative paths.
const { readdirSync } = require("fs");
const { spawnSync } = require("child_process");
const path = require("path");

const root = path.join(__dirname, "..");

function findTests(dir) {
  const found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...findTests(full));
    else if (entry.name.endsWith("_test.lua")) found.push(full);
  }
  return found;
}

const files = findTests(__dirname)
  .map((f) => path.relative(root, f).split(path.sep).join("/"))
  .sort();
let failed = 0;

for (const file of files) {
  console.log(`== ${file}`);
  const result = spawnSync("lua", [file], { cwd: root, stdio: "inherit" });
  if (result.error) {
    console.error(`Could not run lua: ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) failed++;
}

if (files.length === 0) {
  console.error("No *_test.lua files found under tests/.");
  process.exit(1);
}
if (failed > 0) {
  console.error(`${failed} test file(s) failed.`);
  process.exit(1);
}
console.log(`All ${files.length} test file(s) passed.`);
