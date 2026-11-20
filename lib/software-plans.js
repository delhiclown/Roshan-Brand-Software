const SOFTWARE_PLAN_CODES = Object.freeze([
  '2_pnr_30_days',
  '4_pnr_30_days',
  '6_pnr_30_days'
]);

function normalizeSoftwarePlanCode(value) {
  const code = String(value || '').trim().toLowerCase();
  if (!code) return null;
  if (!SOFTWARE_PLAN_CODES.includes(code)) {
    throw new Error('Choose a valid 30-day Software PNR plan.');
  }
  return code;
}

module.exports = { SOFTWARE_PLAN_CODES, normalizeSoftwarePlanCode };
