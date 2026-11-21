const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const publicIndex = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

test('email auth prevents form navigation and restores controls after every result', () => {
  assert.match(publicIndex, /\$\('auth-form'\)\.addEventListener\('submit',submitAuth\)/);
  assert.match(publicIndex, /async function submitAuth\(event\)\{\s*event\.preventDefault\(\)/);
  assert.match(publicIndex, /setAuthBusy\(true,mode\)/);
  assert.match(publicIndex, /finally\{\s*setAuthBusy\(false\);\s*\}/);
  assert.match(publicIndex, /Signing in…/);
  assert.match(publicIndex, /Creating account…/);
});

test('email auth gives actionable errors and does not close without a session', () => {
  assert.match(publicIndex, /email_not_confirmed/);
  assert.match(publicIndex, /invalid login credentials/);
  assert.match(publicIndex, /rate\.\?limit\|too many requests/);
  assert.match(publicIndex, /failed to fetch\|network\|fetch failed/);
  assert.match(publicIndex, /password\.length<6/);
  assert.match(publicIndex, /if\(!data\.session\)\{\s*setAuthMessage\('Email confirmation is required before sign-in/);
  assert.match(publicIndex, /await updateSession\(data\.session\);\s*closeAuthPage\(false\)/);
});

test('signup confirmation, password reset, and Remember me keep visible outcomes', () => {
  assert.match(publicIndex, /state\.client\.auth\.signUp\(/);
  assert.match(publicIndex, /if\(mode==='signup'\)\{[\s\S]*?setRememberSession\(\$\('auth-remember'\)\.checked\);\s*const \{data,error\}=await state\.client\.auth\.signUp/);
  assert.match(publicIndex, /if\(data\.session\)\{\s*await updateSession\(data\.session\);\s*closeAuthPage\(false\)/);
  assert.match(publicIndex, /Account created\. Sign in with your new credentials\./);
  assert.doesNotMatch(publicIndex, /Account created\. Check your email to confirm your address, then sign in\./);
  assert.match(publicIndex, /Apna password yaad rakho\. Nakli email par password reset kaam nahi karega\./);
  assert.match(publicIndex, /resetPasswordForEmail\(email/);
  assert.match(publicIndex, /setRememberSession\(\$\('auth-remember'\)\.checked\)/);
  assert.match(publicIndex, /id="auth-remember" type="checkbox" checked/);
  assert.match(publicIndex, /rememberSession:true/);
  assert.match(publicIndex, /autoRefreshToken:true/);
  assert.match(publicIndex, /state\.client\.auth\.signOut\(\{scope:'local'\}\)/);
  assert.match(publicIndex, /if\(key===authStorageKey\)localStorage\.removeItem\(authSessionExpiryStorageKey\)/);
  assert.doesNotMatch(publicIndex, /Date\.now\(\)\+30\*24\*60\*60\*1000/);
  assert.match(publicIndex, /Could not save the Remember me preference\. Check your browser storage settings and try again\./);
});

test('profile menu My Orders stays inside click handling and uses the orders panel navigation', () => {
  assert.match(publicIndex, /\[data-menu="orders"\]'\)\.addEventListener\('click',\(\)=>openOrdersPanel\(\)\)/);
  assert.match(publicIndex, /!menu\.contains\(event\.target\)&&!event\.target\.closest\('\.avatar-wrap'\)/);
  assert.match(publicIndex, /!event\.target\.closest\('#orders-trigger'\)&&!menu\?\.contains\(event\.target\)/);
  for (const action of ['wallet', 'history', 'logout']) {
    assert.match(publicIndex, new RegExp(`\\[data-menu="${action}"\\]`));
  }
});
