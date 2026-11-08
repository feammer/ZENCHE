import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../', import.meta.url);
const read = async (path) => readFile(new URL(path, root), 'utf8');

test('Windows installer compiles the NSIS script as UTF-8', async () => {
  const [script, nsi] = await Promise.all([
    read('scripts/build-windows.ps1'),
    read('native/windows/Installer/NikonLink.nsi'),
  ]);
  assert.match(script, /INPUTCHARSET/);
  assert.match(script, /UTF8/);
  assert.match(nsi, /"DisplayName" "帧澈 ZENCHE"/);
  assert.match(nsi, /Unicode true/);
});

test('Windows close path tolerates a second close request during cleanup', async () => {
  const source = await read('native/windows/MainWindow.xaml.cs');
  const body = source.slice(
    source.indexOf('private async void Window_Closing('),
    source.indexOf('private async void Window_Closing(') + 4200,
  );
  assert.match(body, /if \(_closeApproved\)/);
  assert.match(body, /if \(_shutdownStarted\)[\s\S]*?e\.Cancel = true;/);
  assert.match(body, /Closing -= Window_Closing;[\s\S]*?_closeApproved = true;[\s\S]*?Close\(\);/);
});

test('Windows exception dialog does not attach a closing owner', async () => {
  const source = await read('native/windows/App.xaml.cs');
  assert.match(source, /var owner = Application\.Current\?\.MainWindow;/);
  assert.match(source, /!ReferenceEquals\(owner, dialog\)/);
  assert.match(source, /catch \(InvalidOperationException\)/);
});
