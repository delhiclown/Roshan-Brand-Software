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

test('email auth distinguishes unconfirmed accounts from invalid credentials', () => {
  assert.match(publicIndex, /email_not_confirmed/);
  assert.match(publicIndex, /invalid login credentials/);
  assert.match(publicIndex, /rate\.\?limit\|too many requests/);
  assert.match(publicIndex, /failed to fetch\|network\|fetch failed/);
  assert.match(publicIndex, /password\.length<8/);
  assert.match(publicIndex, /showAuthOtp\(email,'Please verify your email before signing in\.'\)/);
  assert.match(publicIndex, /await resendAuthOtp\(true\)/);
  assert.match(publicIndex, /Too many requests\. Please wait a minute and try again\./);
  assert.match(publicIndex, /Didn't get the code\? Check your spam folder\./);
  assert.match(publicIndex, /Resend code \(\$\{remaining\}s\)/);
  assert.match(publicIndex, /Date\.now\(\)<authOtpCooldownUntil/);
  assert.match(publicIndex, /await updateSession\(data\.session\);\s*closeAuthPage\(false\)/);
});

test('signup uses separate names, validates passwords, and verifies a six-digit OTP', () => {
  assert.match(publicIndex, /state\.client\.auth\.signUp\(/);
  assert.match(publicIndex, /if\(mode==='signup'\)\{[\s\S]*?setRememberSession\(\$\('auth-remember'\)\.checked\);\s*const \{data,error\}=await state\.client\.auth\.signUp/);
  assert.match(publicIndex, /data:\{first_name:firstName,last_name:lastName,full_name:/);
  assert.match(publicIndex, /password!==\$\(\'login-confirm-password\'\)\.value/);
  assert.match(publicIndex, /verifyOtp\(\{email:authOtpEmail,token,type:'signup'\}\)/);
  assert.match(publicIndex, /resend\(\{type:'signup',email:authOtpEmail\}\)/);
  assert.match(publicIndex, /authOtpCooldownUntil=Date\.now\(\)\+60000/);
  assert.match(publicIndex, /type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6"/);
  assert.match(publicIndex, /id="auth-tab-signin"[^>]*>Login/);
  assert.match(publicIndex, /id="auth-tab-signup"[^>]*>Register/);
  assert.match(publicIndex, /Please enter the code sent to/);
  assert.match(publicIndex, /incorrect or expired/);
  assert.match(publicIndex, /Confirm email is off and no code was sent/);
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

test('signup metadata sanitizer retains first and last names and auth styling stays modal-scoped', () => {
  const migration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'security-admin-authorization-migration.sql'), 'utf8');
  assert.match(migration, /raw_user_meta_data ->> 'first_name'/);
  assert.match(migration, /raw_user_meta_data ->> 'last_name'/);
  assert.match(migration, /'first_name', nullif\(v_first_name, ''\)/);
  assert.match(migration, /'last_name', nullif\(v_last_name, ''\)/);
  assert.match(publicIndex, /metadata\.first_name,metadata\.last_name/);
  assert.match(publicIndex, /if\(intent==='wallet'\)sessionStorage\.setItem\('wallet_pending_open','true'\)/);
  assert.match(publicIndex, /sessionStorage\.setItem\('wallet_pending_product'/);
  assert.match(publicIndex, /Continue as guest/);
});

test('profile menu My Orders stays inside click handling and uses the orders panel navigation', () => {
  assert.match(publicIndex, /\[data-menu="orders"\]'\)\.addEventListener\('click',\(\)=>openOrdersPanel\(\)\)/);
  assert.match(publicIndex, /!menu\.contains\(event\.target\)&&!event\.target\.closest\('\.avatar-wrap'\)/);
  assert.match(publicIndex, /!event\.target\.closest\('#orders-trigger'\)&&!menu\?\.contains\(event\.target\)/);
  for (const action of ['wallet', 'history', 'logout']) {
    assert.match(publicIndex, new RegExp(`\\[data-menu="${action}"\\]`));
  }
});

test('session refresh keeps sign-in active when account detail RPCs partially fail', () => {
  assert.doesNotMatch(publicIndex, /if\(session\?\.\user&&state\.user\?\.\id===session\.user\.id\)return/);
  assert.match(publicIndex, /await Promise\.allSettled\([\s\S]*?refreshWalletBalance\(\)\.catch[\s\S]*?refreshMyCoupons\(\)\.catch/);
  assert.match(publicIndex, /Could not refresh wallet balance/);
  assert.match(publicIndex, /Could not refresh account coupons/);
});
