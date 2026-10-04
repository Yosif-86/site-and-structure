// Stamps the Arc logo, faded, in the middle of every page of a PDF.
// Usage: node stamp-pdf.js <in.pdf> <logo.png> <out.pdf>
// Run by .github/workflows/process-course-file.yml (pdf-lib installed there).

const fs = require('fs');
const { PDFDocument, degrees } = require('pdf-lib');

async function main() {
  const [input, logoPath, output] = process.argv.slice(2);
  if (!input || !logoPath || !output) {
    console.error('usage: node stamp-pdf.js <in.pdf> <logo.png> <out.pdf>');
    process.exit(2);
  }
  const pdf = await PDFDocument.load(fs.readFileSync(input), {
    ignoreEncryption: true,
    updateMetadata: false,
  });
  const logo = await pdf.embedPng(fs.readFileSync(logoPath));
  for (const page of pdf.getPages()) {
    const { width, height } = page.getSize();
    // Logo spans ~45% of the page's shorter side, centred.
    const target = Math.min(width, height) * 0.45;
    const scale = target / Math.max(logo.width, logo.height);
    const w = logo.width * scale;
    const h = logo.height * scale;
    // Pages with a /Rotate are drawn in unrotated space; centre is the same.
    page.drawImage(logo, {
      x: (width - w) / 2,
      y: (height - h) / 2,
      width: w,
      height: h,
      opacity: 0.12,
      rotate: degrees(0),
    });
  }
  pdf.setProducer('Arc Platform');
  fs.writeFileSync(output, await pdf.save());
  console.log(`stamped ${pdf.getPageCount()} pages`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
