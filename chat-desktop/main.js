'use strict';
// Harness Chat desktop: a native window around harness-chat-web (like the
// ChatGPT desktop app). The web app is the product; this shell adds a real
// dock icon, menu, shortcuts, and window chrome.
const { app, BrowserWindow, Menu, shell, session } = require('electron');

const APP_URL = 'https://harness-chat-web.vercel.app/';
let win = null;

function createWindow() {
  win = new BrowserWindow({
    width: 1180, height: 800, minWidth: 700, minHeight: 480,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 14, y: 14 },
    backgroundColor: '#161619',
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });

  // Google rejects OAuth from anything it sniffs as an embedded browser.
  // Chrome-minus-Electron for the app itself, and a real Safari UA for
  // Google's auth domains — the accepted pattern for desktop shells.
  const ua = win.webContents.getUserAgent().replace(/ ?Electron\/[\d.]+/, '').replace(/ ?harness-chat-desktop\/[\d.]+/, '');
  win.webContents.setUserAgent(ua);
  session.defaultSession.setUserAgent(ua);
  const SAFARI_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15';
  session.defaultSession.webRequest.onBeforeSendHeaders((details, cb) => {
    if (/https:\/\/(accounts\.google\.com|accounts\.youtube\.com|ssl\.gstatic\.com|www\.gstatic\.com|apis\.google\.com)/.test(details.url)) {
      details.requestHeaders['User-Agent'] = SAFARI_UA;
    }
    cb({ requestHeaders: details.requestHeaders });
  });

  win.loadURL(APP_URL);

  // make the app's header the drag region + room for traffic lights
  win.webContents.on('did-finish-load', () => {
    win.webContents.insertCSS(`
      header { -webkit-app-region: drag; padding-left: 76px !important; }
      header button, header .icon-btn { -webkit-app-region: no-drag; }
      #side .head { -webkit-app-region: drag; }
      #side .head button { -webkit-app-region: no-drag; }
    `);
  });

  // html live previews (blob:) open as child windows; anything external → browser
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('blob:')) {
      return { action: 'allow', overrideBrowserWindowOptions: { width: 900, height: 700, backgroundColor: '#ffffff' } };
    }
    if (/^https:\/\/(accounts\.google\.com|.*\.supabase\.co)/.test(url)) return { action: 'allow' };
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

function js(code) { if (win) win.webContents.executeJavaScript(code).catch(() => {}); }

app.whenReady().then(() => {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Harness Chat', submenu: [
      { role: 'about' }, { type: 'separator' },
      { role: 'hide' }, { role: 'hideOthers' }, { type: 'separator' }, { role: 'quit' },
    ] },
    { label: 'File', submenu: [
      { label: 'New Chat', accelerator: 'Cmd+N', click: () => js("document.getElementById('newBtn').click()") },
      { type: 'separator' },
      { role: 'close' },
    ] },
    { role: 'editMenu' },
    { label: 'View', submenu: [
      { role: 'reload' }, { type: 'separator' },
      { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' }, { type: 'separator' },
      { role: 'togglefullscreen' },
    ] },
    { role: 'windowMenu' },
  ]));
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); else if (win) win.show(); });
});
app.on('window-all-closed', () => { /* stay in the dock like ChatGPT */ });
