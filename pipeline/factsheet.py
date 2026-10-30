"""Render SUB/NUM financial data into Markdown company fact sheets.

Turns structured XBRL data (SEC Financial Statement Data Sets) into
human-readable fact sheets that can be fed into the RAG pipeline alongside
parsed filings. Each fact sheet covers one company's annual financials.

Usage:
    python -m pipeline.factsheet                          # all companies
    python -m pipeline.factsheet --ticker AAPL            # one company
    python -m pipeline.factsheet --ticker AAPL --year 2023
"""

import argparse
import csv
import os
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# XBRL tag → human-readable label, grouped by financial statement section
# ---------------------------------------------------------------------------

INCOME_STATEMENT = [
    ("Revenues", "Revenue"),
    ("RevenueFromContractWithCustomerExcludingAssessedTax", "Revenue"),
    ("CostOfGoodsAndServicesSold", "Cost of Revenue"),
    ("CostOfRevenue", "Cost of Revenue"),
    ("GrossProfit", "Gross Profit"),
    ("OperatingExpenses", "Operating Expenses"),
    ("ResearchAndDevelopmentExpense", "R&D Expense"),
    ("SellingGeneralAndAdministrativeExpense", "SG&A Expense"),
    ("OperatingIncomeLoss", "Operating Income"),
    ("NonoperatingIncomeExpense", "Non-operating Income"),
    ("InterestExpense", "Interest Expense"),
    ("InterestIncome", "Interest Income"),
    ("IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest", "Pre-tax Income"),
    ("IncomeTaxExpenseBenefit", "Income Tax"),
    ("NetIncomeLoss", "Net Income"),
    ("EarningsPerShareBasic", "EPS (Basic)"),
    ("EarningsPerShareDiluted", "EPS (Diluted)"),
    ("WeightedAverageNumberOfShareOutstandingBasicAndDiluted", "Shares Outstanding"),
    ("WeightedAverageNumberOfDilutedSharesOutstanding", "Diluted Shares"),
]

BALANCE_SHEET = [
    ("CashAndCashEquivalentsAtCarryingValue", "Cash & Equivalents"),
    ("ShortTermInvestments", "Short-term Investments"),
    ("AccountsReceivableNetCurrent", "Accounts Receivable"),
    ("InventoryNet", "Inventory"),
    ("AssetsCurrent", "Total Current Assets"),
    ("PropertyPlantAndEquipmentNet", "PP&E (Net)"),
    ("Goodwill", "Goodwill"),
    ("IntangibleAssetsNetExcludingGoodwill", "Intangible Assets"),
    ("AssetsNoncurrent", "Total Non-current Assets"),
    ("Assets", "Total Assets"),
    ("AccountsPayableCurrent", "Accounts Payable"),
    ("LongTermDebt", "Long-term Debt"),
    ("LongTermDebtNoncurrent", "Long-term Debt"),
    ("DebtCurrent", "Short-term Debt"),
    ("LiabilitiesCurrent", "Total Current Liabilities"),
    ("Liabilities", "Total Liabilities"),
    ("StockholdersEquity", "Stockholders' Equity"),
    ("StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest", "Total Equity"),
    ("RetainedEarningsAccumulatedDeficit", "Retained Earnings"),
    ("AccumulatedOtherComprehensiveIncomeLossNetOfTax", "Accumulated OCI"),
]

CASH_FLOW = [
    ("NetCashProvidedByUsedInOperatingActivities", "Cash from Operations"),
    ("NetCashProvidedByUsedInInvestingActivities", "Cash from Investing"),
    ("NetCashProvidedByUsedInFinancingActivities", "Cash from Financing"),
    ("CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents", "Cash (End of Period)"),
    ("PaymentsToAcquirePropertyPlantAndEquipment", "CapEx"),
    ("PaymentsOfDividends", "Dividends Paid"),
    ("PaymentsForRepurchaseOfCommonStock", "Share Buybacks"),
    ("DepreciationDepletionAndAmortization", "D&A"),
    ("ShareBasedCompensation", "Stock-based Compensation"),
    ("StockIssuedDuringPeriodValueShareBasedCompensation", "Stock-based Compensation"),
]

ALL_SECTIONS = [
    ("Income Statement", INCOME_STATEMENT),
    ("Balance Sheet", BALANCE_SHEET),
    ("Cash Flow Statement", CASH_FLOW),
]


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_sub(sub_path: str) -> Dict[str, dict]:
    """Load SUB rows into {adsh: row_dict}."""
    subs = {}
    with open(sub_path) as f:
        for row in csv.DictReader(f, delimiter="\t"):
            subs[row["adsh"]] = row
    return subs


def load_num(num_path: str) -> List[dict]:
    """Load all NUM rows."""
    rows = []
    with open(num_path) as f:
        for row in csv.DictReader(f, delimiter="\t"):
            rows.append(row)
    return rows


def group_by_company(
    subs: Dict[str, dict], nums: List[dict]
) -> Dict[int, Dict]:
    """Group data by CIK → {cik, name, ticker, filings: {adsh: {sub, nums}}}."""
    companies: Dict[int, Dict] = {}

    for adsh, sub in subs.items():
        cik = int(sub["cik"])
        if cik not in companies:
            companies[cik] = {
                "cik": cik,
                "name": sub["name"],
                "sic": sub.get("sic", ""),
                "state": sub.get("stprba", ""),
                "city": sub.get("cityba", ""),
                "filings": {},
            }
        companies[cik]["filings"][adsh] = {"sub": sub, "nums": []}

    for row in nums:
        adsh = row["adsh"]
        if adsh in subs:
            cik = int(subs[adsh]["cik"])
            if cik in companies and adsh in companies[cik]["filings"]:
                companies[cik]["filings"][adsh]["nums"].append(row)

    return companies


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

PER_SHARE_TAGS = {
    "EarningsPerShareBasic", "EarningsPerShareDiluted",
    "CommonStockDividendsPerShareDeclared",
    "CommonStockDividendsPerShareCashPaid",
}


def _fmt_value(val_str: str, uom: str, tag: str = "") -> str:
    """Format a numeric value for display."""
    try:
        val = float(val_str)
    except (ValueError, TypeError):
        return val_str

    if uom == "USD/shares" or "PerShare" in uom or tag in PER_SHARE_TAGS:
        return f"${val:,.2f}"
    elif uom == "shares":
        if abs(val) >= 1e9:
            return f"{val / 1e9:,.1f}B"
        elif abs(val) >= 1e6:
            return f"{val / 1e6:,.0f}M"
        return f"{val:,.0f}"
    elif uom == "USD":
        if abs(val) >= 1e9:
            return f"${val / 1e9:,.1f}B"
        elif abs(val) >= 1e6:
            return f"${val / 1e6:,.0f}M"
        elif abs(val) >= 1e3:
            return f"${val / 1e3:,.0f}K"
        return f"${val:,.2f}"
    elif uom == "pure":
        return f"{val:,.4f}"
    else:
        return f"{val:,.0f} {uom}"


def render_factsheet(
    company: Dict,
    year: Optional[int] = None,
) -> Optional[str]:
    """Render a Markdown fact sheet for one company.

    If year is specified, renders only that fiscal year's 10-K.
    Otherwise renders the most recent 10-K available.
    """
    # Find annual filings (10-K)
    annual_filings = []
    for adsh, filing in company["filings"].items():
        sub = filing["sub"]
        if sub["form"] == "10-K":
            fy = int(sub["fy"]) if sub["fy"] else 0
            annual_filings.append((fy, adsh, filing))

    if not annual_filings:
        return None

    annual_filings.sort(key=lambda x: x[0], reverse=True)

    if year:
        match = [f for f in annual_filings if f[0] == year]
        if not match:
            return None
        target = match[0]
    else:
        target = annual_filings[0]

    fy, adsh, filing = target
    sub = filing["sub"]
    nums = filing["nums"]

    # Filter to unsegmented, annual (qtrs=0 or qtrs=4), most recent ddate
    annual_nums = [
        r for r in nums
        if not r.get("segments") and r["qtrs"] in ("0", "4")
    ]

    # For each tag, pick the row with the most recent ddate (current period)
    tag_values: Dict[str, Tuple[str, str, str]] = {}
    for row in annual_nums:
        tag = row["tag"]
        ddate = row["ddate"]
        if tag not in tag_values or ddate > tag_values[tag][2]:
            tag_values[tag] = (row["value"], row["uom"], ddate)

    available_tags = set(tag_values.keys())

    lines = []
    lines.append(f"# {company['name']} — FY{fy} Financial Fact Sheet")
    lines.append("")
    lines.append(f"- **CIK:** {company['cik']}")
    lines.append(f"- **SIC:** {company['sic']}")
    if company["city"] and company["state"]:
        lines.append(f"- **Headquarters:** {company['city']}, {company['state']}")
    lines.append(f"- **Fiscal Year End:** {sub['period'][:4]}-{sub['period'][4:6]}-{sub['period'][6:]}")
    lines.append(f"- **Filed:** {sub['filed'][:4]}-{sub['filed'][4:6]}-{sub['filed'][6:]}")
    lines.append(f"- **Accession:** {adsh}")
    lines.append("")

    for section_name, tags in ALL_SECTIONS:
        rendered_labels = set()
        section_lines = []
        for xbrl_tag, label in tags:
            if xbrl_tag in available_tags and label not in rendered_labels:
                val, uom, _ = tag_values[xbrl_tag]
                formatted = _fmt_value(val, uom, tag=xbrl_tag)
                section_lines.append(f"| {label} | {formatted} |")
                rendered_labels.add(label)

        if section_lines:
            lines.append(f"## {section_name}")
            lines.append("")
            lines.append("| Item | Value |")
            lines.append("|------|-------|")
            lines.extend(section_lines)
            lines.append("")

    # Add quarterly trend if we have quarterly data
    quarterly_filings = []
    for a, f in company["filings"].items():
        s = f["sub"]
        if s["form"] == "10-Q":
            quarterly_filings.append((s["period"], a, f))
    quarterly_filings.sort()

    if quarterly_filings:
        revenue_tag = None
        for tag_name in ("Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax"):
            if any(r["tag"] == tag_name for qf in quarterly_filings for r in qf[2]["nums"]):
                revenue_tag = tag_name
                break

        net_income_tag = "NetIncomeLoss"

        if revenue_tag:
            lines.append("## Quarterly Revenue Trend")
            lines.append("")
            lines.append("| Quarter | Revenue | Net Income |")
            lines.append("|---------|---------|------------|")

            for period, a, qf in quarterly_filings:
                sub_q = qf["sub"]
                q_label = f"FY{sub_q['fy']} {sub_q['fp']}"

                # Get quarterly values (qtrs=1, no segments, most recent ddate).
                # A 10-Q also carries the prior-year comparative for the same
                # tag, so keep only the latest ddate per tag — otherwise the
                # comparative can overwrite the current period.
                q_nums = [r for r in qf["nums"] if r["qtrs"] == "1" and not r.get("segments")]

                q_latest: Dict[str, dict] = {}
                for r in q_nums:
                    if r["tag"] not in q_latest or r["ddate"] > q_latest[r["tag"]]["ddate"]:
                        q_latest[r["tag"]] = r

                rev = ""
                ni = ""
                if revenue_tag in q_latest:
                    r = q_latest[revenue_tag]
                    rev = _fmt_value(r["value"], r["uom"], tag=r["tag"])
                if net_income_tag in q_latest:
                    r = q_latest[net_income_tag]
                    ni = _fmt_value(r["value"], r["uom"], tag=r["tag"])

                if rev or ni:
                    lines.append(f"| {q_label} | {rev} | {ni} |")

            lines.append("")

    return "\n".join(lines)


def render_all(
    sub_path: str,
    num_path: str,
    output_dir: str,
    ticker_filter: Optional[str] = None,
    year_filter: Optional[int] = None,
    ticker_lookup: Optional[Dict[int, str]] = None,
) -> List[str]:
    """Render fact sheets for all companies and write to output_dir."""
    subs = load_sub(sub_path)
    nums = load_num(num_path)
    companies = group_by_company(subs, nums)

    os.makedirs(output_dir, exist_ok=True)
    written = []

    for cik, company in sorted(companies.items(), key=lambda x: x[1]["name"]):
        ticker = ""
        if ticker_lookup and cik in ticker_lookup:
            ticker = ticker_lookup[cik]

        if ticker_filter and ticker.upper() != ticker_filter.upper():
            continue

        md = render_factsheet(company, year=year_filter)
        if not md:
            continue

        fname = f"{ticker}_{cik}" if ticker else str(cik)
        if year_filter:
            fname += f"_FY{year_filter}"
        fname += ".md"

        out_path = os.path.join(output_dir, fname)
        with open(out_path, "w") as f:
            f.write(md)
        written.append(out_path)

    return written


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Render financial fact sheets from SUB/NUM data")
    parser.add_argument("--sub", default="data/seed/postgres/sub.tsv", help="Path to sub.tsv")
    parser.add_argument("--num", default="data/seed/postgres/num.tsv", help="Path to num.tsv")
    parser.add_argument("--output", default="data/seed/factsheets", help="Output directory")
    parser.add_argument("--ticker", help="Filter to one ticker")
    parser.add_argument("--year", type=int, help="Filter to one fiscal year")
    parser.add_argument("--manifest", default="data/seed/manifests/seed-manifest.json",
                        help="Seed manifest for ticker→CIK mapping")
    args = parser.parse_args()

    # Build ticker→CIK lookup from manifest
    ticker_lookup: Dict[int, str] = {}
    if os.path.isfile(args.manifest):
        import json
        manifest = json.load(open(args.manifest))
        for category in ("legal", "compliance"):
            for entry in manifest.get(category, []):
                cik = entry.get("cik")
                ticker = entry.get("ticker", "")
                if cik and ticker:
                    ticker_lookup[int(cik)] = ticker

    written = render_all(
        args.sub, args.num, args.output,
        ticker_filter=args.ticker,
        year_filter=args.year,
        ticker_lookup=ticker_lookup,
    )

    print(f"Wrote {len(written)} fact sheets to {args.output}")
    for p in written[:5]:
        print(f"  {p}")
    if len(written) > 5:
        print(f"  ... and {len(written) - 5} more")


if __name__ == "__main__":
    main()
