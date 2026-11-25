const SOFTWARE_PLAN_CODES = Object.freeze([
  '2_pnr_30_days',
  '4_pnr_30_days',
  '6_pnr_30_days',
  'windows_vps_4gb',
  'windows_vps_8gb',
  'windows_vps_16gb',
  'windows_vps_32gb'
]);

function normalizeSoftwarePlanCode(value) {
  const code = String(value || '').trim().toLowerCase();
  if (!code) return null;
  if (!SOFTWARE_PLAN_CODES.includes(code)) {
    throw new Error('Choose a valid 30-day Software PNR plan or Windows VPS option.');
  }
  return code;
}

module.exports = { SOFTWARE_PLAN_CODES, normalizeSoftwarePlanCode };
