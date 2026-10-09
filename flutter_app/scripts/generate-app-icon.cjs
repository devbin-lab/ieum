// Requires Node.js and sharp. Rasterize the editable SVG into PNG/ICO assets.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');

async function main() {
  const root = path.resolve(__dirname, '..');
  const source = await fs.readFile(path.join(root, 'assets/branding/app_icon.svg'));
  await sharp(source).png().toFile(path.join(root, 'assets/branding/app_icon.png'));

  const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  const frames = await Promise.all(
    sizes.map((size) => sharp(source).resize(size, size).png().toBuffer()),
  );
  const header = Buffer.alloc(6 + 16 * sizes.length);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  for (let i = 0; i < sizes.length; i++) {
    const entry = 6 + 16 * i;
    header[entry] = sizes[i] === 256 ? 0 : sizes[i];
    header[entry + 1] = header[entry];
    header.writeUInt16LE(1, entry + 4);
    header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(frames[i].length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += frames[i].length;
  }
  await fs.writeFile(
    path.join(root, 'windows/runner/resources/app_icon.ico'),
    Buffer.concat([header, ...frames]),
  );
  console.log(`Generated app_icon.png and app_icon.ico (${sizes.join(', ')} px).`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
