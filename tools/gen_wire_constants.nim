## Emits the JS wire-constants block (src/coins/wire_constants.nim) on
## stdout. The static replay-viewer bundle can't run a compile-time splice,
## so Dockerfile.replay-viewer runs this to write dist/wire_constants.js and
## injects a <script src> for it into the bundled page.
import ../src/coins/wire_constants

echo WireConstantsJs
