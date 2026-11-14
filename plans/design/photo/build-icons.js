// Inlines the Phosphor icons the mockup uses (design/icons/phosphor) into icons.js.
const fs = require('fs'), path = require('path');
const names = 'house user video-camera file-text scissors list-bullets book-open-text paper-plane-tilt plus sliders-horizontal magnifying-glass chat-circle-text camera arrows-left-right squares-four arrows-clockwise dots-three t-shirt package images image frame-corners aperture sun palette caret-down caret-left caret-right check arrow-clockwise arrows-out-simple export stack x lock-simple shuffle'.split(' ');
const root = path.join(__dirname, '../../../design/icons/phosphor');
const map = Object.fromEntries(names.map(n => [n, fs.readFileSync(path.join(root, n + '.svg'), 'utf8').replace(/\n/g, '')]));
fs.writeFileSync(path.join(__dirname, 'icons.js'), 'window.ICONS=' + JSON.stringify(map) + ';\n');
