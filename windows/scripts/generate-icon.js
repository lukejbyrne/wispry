const fs = require("fs");
const path = require("path");

const SIZE = 256;
const BUILD_DIR = path.join(__dirname, "..", "build");
const ICON_PATH = path.join(BUILD_DIR, "icon.ico");

function main() {
  fs.mkdirSync(BUILD_DIR, { recursive: true });
  fs.writeFileSync(ICON_PATH, createIco());
  console.log(`Generated ${ICON_PATH}`);
}

function createIco() {
  const rgba = new Uint8ClampedArray(SIZE * SIZE * 4);

  drawRoundedRect(rgba, 24, 24, 208, 208, 56, [238, 244, 208, 255]);
  drawRoundedRect(rgba, 84, 55, 88, 122, 42, [17, 19, 15, 255]);
  drawRoundedRect(rgba, 103, 55, 50, 100, 25, [238, 244, 208, 255]);
  strokeArc(rgba, 128, 141, 68, Math.PI * 0.1, Math.PI * 0.9, 14, [17, 19, 15, 255]);
  drawRoundedRect(rgba, 119, 198, 18, 28, 9, [17, 19, 15, 255]);
  drawRoundedRect(rgba, 93, 219, 70, 14, 7, [17, 19, 15, 255]);

  const pixels = Buffer.alloc(SIZE * SIZE * 4);
  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const source = ((SIZE - 1 - y) * SIZE + x) * 4;
      const target = (y * SIZE + x) * 4;
      pixels[target] = rgba[source + 2];
      pixels[target + 1] = rgba[source + 1];
      pixels[target + 2] = rgba[source];
      pixels[target + 3] = rgba[source + 3];
    }
  }

  const mask = Buffer.alloc(Math.ceil(SIZE / 32) * 4 * SIZE);
  const bitmapHeader = Buffer.alloc(40);
  bitmapHeader.writeUInt32LE(40, 0);
  bitmapHeader.writeInt32LE(SIZE, 4);
  bitmapHeader.writeInt32LE(SIZE * 2, 8);
  bitmapHeader.writeUInt16LE(1, 12);
  bitmapHeader.writeUInt16LE(32, 14);
  bitmapHeader.writeUInt32LE(0, 16);
  bitmapHeader.writeUInt32LE(pixels.length, 20);

  const image = Buffer.concat([bitmapHeader, pixels, mask]);
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(1, 4);

  const entry = Buffer.alloc(16);
  entry[0] = 0;
  entry[1] = 0;
  entry[2] = 0;
  entry[3] = 0;
  entry.writeUInt16LE(1, 4);
  entry.writeUInt16LE(32, 6);
  entry.writeUInt32LE(image.length, 8);
  entry.writeUInt32LE(header.length + entry.length, 12);

  return Buffer.concat([header, entry, image]);
}

function drawRoundedRect(rgba, x, y, width, height, radius, color) {
  for (let py = y; py < y + height; py += 1) {
    for (let px = x; px < x + width; px += 1) {
      const dx = Math.max(x - px + radius, 0, px - (x + width - radius - 1));
      const dy = Math.max(y - py + radius, 0, py - (y + height - radius - 1));
      if (dx * dx + dy * dy <= radius * radius) {
        setPixel(rgba, px, py, color);
      }
    }
  }
}

function strokeArc(rgba, centerX, centerY, radius, start, end, thickness, color) {
  for (let py = centerY - radius - thickness; py <= centerY + radius + thickness; py += 1) {
    for (let px = centerX - radius - thickness; px <= centerX + radius + thickness; px += 1) {
      const dx = px - centerX;
      const dy = py - centerY;
      const distance = Math.sqrt(dx * dx + dy * dy);
      const angle = Math.atan2(dy, dx);
      const normalized = angle < 0 ? angle + Math.PI * 2 : angle;
      if (distance >= radius - thickness / 2 && distance <= radius + thickness / 2 && normalized >= start && normalized <= end) {
        setPixel(rgba, px, py, color);
      }
    }
  }
}

function setPixel(rgba, x, y, color) {
  if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) {
    return;
  }
  const index = (y * SIZE + x) * 4;
  rgba[index] = color[0];
  rgba[index + 1] = color[1];
  rgba[index + 2] = color[2];
  rgba[index + 3] = color[3];
}

main();
