#!/usr/bin/env node
// Renders art/friendly-forever-icon.svg to Media/Icon.tga, the in-game icon
// (#65): 64x64, uncompressed 32-bit TGA with an alpha channel, the format
// WoW loads. Needs Node and Playwright's Chromium; release builds never run
// it, they ship the committed TGA.
//
//   node scripts/render-icon.js
"use strict";

const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const ROOT = path.resolve(__dirname, "..");
const SOURCE = path.join(ROOT, "art", "friendly-forever-icon.svg");
const OUT = path.join(ROOT, "Media", "Icon.tga");
const SIZE = 64;

// Uncompressed true-colour TGA: 18-byte header, then BGRA rows from the
// bottom up (descriptor 0x08: 8 alpha bits, bottom-left origin).
function tga(rgba, size) {
    const header = Buffer.alloc(18);
    header[2] = 2;
    header.writeUInt16LE(size, 12);
    header.writeUInt16LE(size, 14);
    header[16] = 32;
    header[17] = 0x08;
    const pixels = Buffer.alloc(size * size * 4);
    for (let y = 0; y < size; y++) {
        const row = (size - 1 - y) * size * 4;
        for (let x = 0; x < size; x++) {
            const from = (y * size + x) * 4;
            const to = row + x * 4;
            pixels[to] = rgba[from + 2];
            pixels[to + 1] = rgba[from + 1];
            pixels[to + 2] = rgba[from];
            pixels[to + 3] = rgba[from + 3];
        }
    }
    return Buffer.concat([header, pixels]);
}

async function main() {
    const svg = fs.readFileSync(SOURCE, "utf8");
    const browser = await chromium.launch();
    try {
        const page = await browser.newPage();
        const rgba = await page.evaluate(async ({ svg, size }) => {
            const img = new Image();
            img.src = "data:image/svg+xml;base64," + btoa(svg);
            await img.decode();
            const canvas = document.createElement("canvas");
            canvas.width = canvas.height = size;
            const ctx = canvas.getContext("2d");
            ctx.drawImage(img, 0, 0, size, size);
            return Array.from(ctx.getImageData(0, 0, size, size).data);
        }, { svg, size: SIZE });

        fs.mkdirSync(path.dirname(OUT), { recursive: true });
        fs.writeFileSync(OUT, tga(rgba, SIZE));
        console.log(OUT);
    } finally {
        await browser.close();
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
