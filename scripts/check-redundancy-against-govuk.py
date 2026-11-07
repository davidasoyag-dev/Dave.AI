#!/usr/bin/env python3
"""Compare Dave.AI's redundancy calculator with GOV.UK's own calculator on random cases.
Needs Node:  python3 scripts/check-redundancy-against-govuk.py
Re-run each April (the weekly pay cap changes). Uses ~60 polite requests to GOV.UK."""
import json, random, re, subprocess, sys, time, urllib.request
random.seed(7)
def page(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers={'User-Agent': 'Dave.AI accuracy check'}), timeout=30).read().decode('utf-8', 'ignore')
cases = []
while len(cases) < 60:
    c = dict(date=random.choice(['2026-10-27', '2027-01-15', '2026-12-31']), age=random.randint(18, 65), years=random.choice([2, 3, 5, 8, 12, 15, 20, 25]), pay=random.choice([150, 451, 620, 751, 900, 1200]))
    if c['age'] - c['years'] >= 16: cases.append(c)
bad = 0
for c in cases:
    t = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', re.sub(r'<script.*?</script>', ' ', page('https://www.gov.uk/calculate-your-redundancy-pay/y/%s/%d/%d/%d' % (c['date'], c['age'], c['years'], c['pay'])), flags=re.S)))
    gov = float(re.search(r'redundancy payment is £([\d,]+)', t).group(1).replace(',', '')); cap = float(re.search(r'capped at £([\d,]+)', t).group(1).replace(',', ''))
    y, rest = c['date'].split('-', 1)
    js = "const c=require('./netlify/lib/search.js');console.log(c.calcRedundancy(%s))" % json.dumps(dict(age_at_dismissal=c['age'], start_date='%d-%s' % (int(y) - c['years'], rest), dismissal_date=c['date'], weekly_pay=c['pay'], weekly_pay_cap=cap))
    out = subprocess.run(['node', '-e', js], capture_output=True, text=True).stdout
    m = re.search(r'= £([\d,]+\.\d\d)', out); mine = float(m.group(1).replace(',', '')) if m else 0.0
    if abs(mine - gov) > 0.01: bad += 1; print('MISMATCH', c, 'gov', gov, 'mine', mine)
    time.sleep(0.4)
print('%d cases, %d mismatches' % (len(cases), bad)); sys.exit(1 if bad else 0)
