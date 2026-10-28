// Accuracy tests for the Research calculators (netlify/lib/search.js).
// Run with Node:  node netlify/tests/calculators.test.js
// Redundancy cases were checked against GOV.UK's own calculator
// (scripts/check-redundancy-against-govuk.py re-runs that comparison; re-run it each April
// when the weekly pay cap changes). Notice and time-limit cases come from the statutory rules.
const assert = require('assert');
const c = require('../lib/search.js');
const has = (out, text) => assert.ok(out.indexOf(text) !== -1, 'expected "' + text + '" in:\n' + out);

// Redundancy (s.162): verified against GOV.UK
has(c.calcRedundancy({ age_at_dismissal: 43, start_date: '2014-10-27', dismissal_date: '2026-10-27', weekly_pay: 620, weekly_pay_cap: 751 }), '= £8,060.00');
has(c.calcRedundancy({ age_at_dismissal: 43, start_date: '2014-10-27', dismissal_date: '2026-10-27', weekly_pay: 620, weekly_pay_cap: 751 }), 'Total: 13 week');
has(c.calcRedundancy({ age_at_dismissal: 42, start_date: '2007-10-27', dismissal_date: '2026-10-27', weekly_pay: 150, weekly_pay_cap: 751 }), '= £2,925.00');
has(c.calcRedundancy({ age_at_dismissal: 30, start_date: '2025-10-28', dismissal_date: '2026-10-27', weekly_pay: 500 }), '£0.00');

// Notice (s.86) boundaries
has(c.calcNotice({ start_date: '2024-10-27', notice_given_date: '2026-10-27' }), 'Statutory minimum notice: 2 week');
has(c.calcNotice({ start_date: '2024-10-28', notice_given_date: '2026-10-27' }), 'Statutory minimum notice: 1 week');
has(c.calcNotice({ start_date: '2026-09-27', notice_given_date: '2026-10-27' }), 'Statutory minimum notice: 1 week');
has(c.calcNotice({ start_date: '2026-09-28', notice_given_date: '2026-10-27' }), 'Statutory minimum notice: 0 week');
has(c.calcNotice({ start_date: '2014-10-27', notice_given_date: '2026-10-27' }), 'Statutory minimum notice: 12 week');
has(c.calcNotice({ start_date: '2014-10-28', notice_given_date: '2026-10-27' }), 'Statutory minimum notice: 11 week');
has(c.calcNotice({ start_date: '2020-02-29', notice_given_date: '2024-02-28' }), 'Statutory minimum notice: 3 week');

// Time limits (s.111, s.207B)
has(c.calcTimeLimit({ event_date: '2026-09-03' }), 'Wednesday 2 December 2026');
has(c.calcTimeLimit({ event_date: '2026-09-03', ec_day_a: '2026-10-01', ec_day_b: '2026-10-15' }), 'Wednesday 16 December 2026');
has(c.calcTimeLimit({ event_date: '2026-09-03', ec_day_a: '2026-11-20', ec_day_b: '2026-11-25' }), 'Friday 25 December 2026');
has(c.calcTimeLimit({ event_date: '2026-11-30' }), 'MONTH-END EDGE CASE');

// Arithmetic
has(c.calcArithmetic({ expression: 'min(620, 700) * 13' }), '= 8060');
has(c.calcArithmetic({ expression: 'process.exit()' }), 'Could not');
console.log('all calculator tests passed');
