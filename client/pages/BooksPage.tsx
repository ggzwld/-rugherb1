import { FormEvent, useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../components/ui/tabs";
import { useToast } from "../hooks/use-toast";
import {
  ArrowDownToLine,
  ArrowUpRight,
  BarChart3,
  BookOpen,
  CircleDollarSign,
  FileText,
  Plus,
  Receipt,
  RefreshCw,
  Users,
} from "lucide-react";

type Contact = { id: string; name: string; type: "customer" | "vendor" | "both"; email: string | null; tax_id: string | null };
type Invoice = { id: string; invoice_number: string; contact_id: string | null; issue_date: string; due_date: string; currency_code: string; subtotal: number; tax_amount: number; total_due: number; status: "draft" | "sent" | "paid" | "overdue" | "void" };
type Expense = { id: string; description: string; contact_id: string | null; expense_date: string; currency_code: string; amount: number; tax_amount: number; payment_status: "paid" | "unpaid" };
type Account = { id: string; code: string; name: string; type: "asset" | "liability" | "equity" | "income" | "expense" };
type TaxRate = { id: string; name: string; country_code: string; rate_percentage: number };
type LedgerLine = { account_id: string; debit: number; credit: number; currency_code: string; transaction_date: string };
type LoyaltyPosting = { ledger_entry_id: string; amount_ugx: number; status: "pending" | "posted" | "failed"; journal_transaction_id: string | null; error_message: string | null; created_at: string };

const today = new Date().toISOString().slice(0, 10);
const formatMoney = (value: number, currency: string) => new Intl.NumberFormat(undefined, { style: "currency", currency: currency.trim(), maximumFractionDigits: currency.trim() === "UGX" ? 0 : 2 }).format(value || 0);
const supportedCurrencies = ["UGX", "USD", "EUR", "GBP", "KES", "TZS", "RWF"];

type CurrencyTotals = { currency_code: string; invoice_total: number; income: number; expenses: number; net_result: number; tax_total: number; receivables: number; assets: number; liabilities: number; equity: number };

type SupabaseErrorLike = { code?: string | null; message?: string | null; details?: string | null; hint?: string | null };
type BooksOperation = "books.load" | "books.contact.save" | "books.invoice.save" | "books.expense.save" | "books.invoice.markPaid";

const newCorrelationId = () => {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  return `books-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

const sanitizeDiagnosticValue = (value: unknown) => typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 500) : value;
const reportBooksError = (operation: BooksOperation, correlationId: string, organizationId: string | null, recordId: string | null, error: SupabaseErrorLike) => {
  console.error("Books operation failed", {
    operation,
    correlationId,
    organizationId,
    recordId,
    supabase: {
      code: sanitizeDiagnosticValue(error.code),
      message: sanitizeDiagnosticValue(error.message),
      details: sanitizeDiagnosticValue(error.details),
      hint: sanitizeDiagnosticValue(error.hint),
    },
  });
};
const operationToast = (title: string, correlationId: string) => ({ title, description: `Please try again. If the problem continues, share reference ${correlationId} with support.`, variant: "destructive" as const });

const BooksPage = () => {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { toast } = useToast();
  const [organizationId, setOrganizationId] = useState<string | null>(null);
  const [baseCurrency, setBaseCurrency] = useState("UGX");
  const requestedCurrency = searchParams.get("currency");
  const [targetCurrency, setTargetCurrency] = useState(requestedCurrency && supportedCurrencies.includes(requestedCurrency) ? requestedCurrency : "USD");
  const [fxRates, setFxRates] = useState<Record<string, number>>({ UGX: 1 });
  const [fxAsOf, setFxAsOf] = useState<string | null>(null);
  const [fxError, setFxError] = useState("");
  const [currencyTotals, setCurrencyTotals] = useState<CurrencyTotals[]>([]);
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [taxRates, setTaxRates] = useState<TaxRate[]>([]);
  const [ledgerLines, setLedgerLines] = useState<LedgerLine[]>([]);
  const [loyaltyPostings, setLoyaltyPostings] = useState<LoyaltyPosting[]>([]);
  const [activeTab, setActiveTab] = useState("overview");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [contactForm, setContactForm] = useState({ name: "", type: "customer" as Contact["type"], email: "", tax_id: "" });
  const [invoiceForm, setInvoiceForm] = useState({ invoice_number: "", contact_id: "", issue_date: today, due_date: today, subtotal: "", tax_rate_id: "" });
  const [expenseForm, setExpenseForm] = useState({ description: "", contact_id: "", expense_date: today, amount: "", tax_amount: "" });

  const loadBooks = async () => {
    const operation: BooksOperation = "books.load";
    const correlationId = newCorrelationId();
    setLoading(true);
    try {
      const { data: userData, error: authError } = await supabase.auth.getUser();
      if (authError) {
        reportBooksError(operation, correlationId, organizationId, null, authError);
        toast(operationToast("Books could not verify your session", correlationId));
        return;
      }
      if (!userData.user) {
        navigate(`/login?returnTo=${encodeURIComponent("/books")}`, { replace: true });
        return;
      }
      const { data: orgId, error: orgError } = await supabase.rpc("get_or_create_books_organization");
      if (orgError || !orgId) {
        if (orgError) reportBooksError(operation, correlationId, null, null, orgError);
        toast(operationToast("Books could not initialize your workspace", correlationId));
        return;
      }
      setOrganizationId(orgId);
      const [org, contactResult, invoiceResult, expenseResult, accountResult, taxResult, transactionResult, loyaltyPostingResult] = await Promise.all([
        supabase.from("books_organizations").select("base_currency").eq("id", orgId).single(),
        supabase.from("books_contacts").select("id,name,type,email,tax_id").eq("organization_id", orgId).order("name"),
        supabase.from("books_invoices").select("id,invoice_number,contact_id,issue_date,due_date,currency_code,subtotal,tax_amount,total_due,status").eq("organization_id", orgId).order("issue_date", { ascending: false }),
        supabase.from("books_expenses").select("id,description,contact_id,expense_date,currency_code,amount,tax_amount,payment_status").eq("organization_id", orgId).order("expense_date", { ascending: false }),
        supabase.from("books_accounts").select("id,code,name,type").eq("organization_id", orgId).order("code"),
        supabase.from("books_tax_rates").select("id,name,country_code,rate_percentage").eq("organization_id", orgId).eq("is_active", true).order("name"),
        supabase.from("books_journal_transactions").select("id,transaction_date,books_journal_lines(account_id,debit,credit,currency_code)").eq("organization_id", orgId).order("transaction_date", { ascending: false }),
        supabase.from("hotel_loyalty_books_postings").select("ledger_entry_id,amount_ugx,status,journal_transaction_id,error_message,created_at").eq("organization_id", orgId).order("created_at", { ascending: false }).limit(20),
      ]);
      const results = [org, contactResult, invoiceResult, expenseResult, accountResult, taxResult, transactionResult];
      const failedResult = results.find((result) => result.error);
      if (failedResult?.error) {
        reportBooksError(operation, correlationId, orgId, null, failedResult.error);
        toast(operationToast("Books could not refresh your records", correlationId));
        return;
      }
      if (org.data?.base_currency) setBaseCurrency(org.data.base_currency.trim());
      setContacts((contactResult.data || []) as Contact[]);
      setInvoices((invoiceResult.data || []) as Invoice[]);
      setExpenses((expenseResult.data || []) as Expense[]);
      setAccounts((accountResult.data || []) as Account[]);
      setTaxRates((taxResult.data || []) as TaxRate[]);
      if (!loyaltyPostingResult.error) setLoyaltyPostings((loyaltyPostingResult.data || []) as LoyaltyPosting[]);
      const transactions = (transactionResult.data || []) as Array<{ id: string; transaction_date: string; books_journal_lines: Array<{ account_id: string; debit: number; credit: number; currency_code: string }> }>;
      setLedgerLines(transactions.flatMap((transaction) => transaction.books_journal_lines.map((line) => ({ ...line, transaction_date: transaction.transaction_date }))));
      const { data: totals, error: totalsError } = await supabase.rpc("get_books_currency_totals", { target_organization_id: orgId });
      if (totalsError) throw totalsError;
      setCurrencyTotals((totals || []) as CurrencyTotals[]);
      await refreshExchangeRates();
    } catch (error) {
      reportBooksError(operation, correlationId, organizationId, null, error as SupabaseErrorLike);
      toast(operationToast("Books could not refresh your records", correlationId));
    } finally {
      setLoading(false);
    }
  };

  const refreshExchangeRates = async () => {
    try {
      const response = await fetch("/api/books/fx-rates");
      const payload = await response.json() as { rates?: Record<string, number>; asOf?: string; error?: string };
      if (!response.ok || !payload.rates) throw new Error(payload.error || "Exchange rates could not be refreshed");
      setFxRates(payload.rates);
      setFxAsOf(payload.asOf || null);
      setFxError("");
    } catch (error) {
      setFxError(error instanceof Error ? error.message : "Exchange rates could not be refreshed");
    }
  };

  useEffect(() => { void loadBooks(); }, []);

  const viewMode = searchParams.get("view");
  const isConsolidatedView = viewMode === "consolidated";
  const isUsdView = viewMode === "usd";
  const currency = isConsolidatedView ? targetCurrency : isUsdView ? "USD" : baseCurrency;
  const visibleInvoices = invoices.filter((invoice) => invoice.currency_code.trim() === currency);
  const visibleExpenses = expenses.filter((expense) => expense.currency_code.trim() === currency);
  const visibleLedgerLines = ledgerLines.filter((line) => line.currency_code.trim() === currency);
  const customerContacts = contacts.filter((contact) => contact.type === "customer" || contact.type === "both");
  const vendorContacts = contacts.filter((contact) => contact.type === "vendor" || contact.type === "both");
  const accountById = new Map(accounts.map((account) => [account.id, account]));
  const ledgerTotal = (type: Account["type"], side: "debit" | "credit") => visibleLedgerLines.reduce((sum, line) => {
    const account = accountById.get(line.account_id);
    return account?.type === type ? sum + Number(line[side]) : sum;
  }, 0);
  const revenue = visibleInvoices.filter((invoice) => ["sent", "overdue", "paid"].includes(invoice.status)).reduce((sum, invoice) => sum + Number(invoice.subtotal), 0);
  const expensesTotal = visibleExpenses.reduce((sum, expense) => sum + Number(expense.amount) + Number(expense.tax_amount), 0);
  const assets = ledgerTotal("asset", "debit") - ledgerTotal("asset", "credit");
  const liabilities = ledgerTotal("liability", "credit") - ledgerTotal("liability", "debit");
  const equity = ledgerTotal("equity", "credit") - ledgerTotal("equity", "debit") + revenue - expensesTotal;
  const openInvoices = visibleInvoices.filter((invoice) => invoice.status === "sent" || invoice.status === "overdue");
  const receivable = openInvoices.reduce((sum, invoice) => sum + Number(invoice.total_due), 0);
  const overdue = visibleInvoices.filter((invoice) => invoice.status === "overdue" || (invoice.status !== "paid" && invoice.due_date < today)).length;
  const contactName = (id: string | null) => contacts.find((contact) => contact.id === id)?.name || "Unassigned";
  const profit = revenue - expensesTotal;
  const fxFactor = (sourceCurrency: string) => {
    const sourceRate = fxRates[sourceCurrency.trim()];
    const destinationRate = fxRates[targetCurrency];
    return sourceRate && destinationRate ? destinationRate / sourceRate : null;
  };
  const convertTotal = (field: keyof Omit<CurrencyTotals, "currency_code">) => currencyTotals.reduce((sum, row) => {
    const factor = fxFactor(row.currency_code);
    return factor === null ? sum : sum + Number(row[field]) * factor;
  }, 0);
  const hasAllConversionRates = currencyTotals.every((row) => fxFactor(row.currency_code) !== null);

  const saveContact = async (event: FormEvent) => {
    event.preventDefault();
    if (!organizationId || !contactForm.name.trim()) return;
    const operation: BooksOperation = "books.contact.save";
    const correlationId = newCorrelationId();
    setSaving(true);
    try {
      const { error } = await supabase.from("books_contacts").insert({ organization_id: organizationId, name: contactForm.name.trim(), type: contactForm.type, email: contactForm.email.trim() || null, tax_id: contactForm.tax_id.trim() || null });
      if (error) {
        reportBooksError(operation, correlationId, organizationId, null, error);
        toast(operationToast("Could not save contact", correlationId));
        return;
      }
      setContactForm({ name: "", type: "customer", email: "", tax_id: "" });
      toast({ title: "Contact added" });
      await loadBooks();
    } catch (error) {
      reportBooksError(operation, correlationId, organizationId, null, error as SupabaseErrorLike);
      toast(operationToast("Could not save contact", correlationId));
    } finally {
      setSaving(false);
    }
  };

  const saveInvoice = async (event: FormEvent) => {
    event.preventDefault();
    if (!organizationId || !invoiceForm.invoice_number.trim() || !invoiceForm.subtotal) return;
    const operation: BooksOperation = "books.invoice.save";
    const correlationId = newCorrelationId();
    setSaving(true);
    try {
      const selectedRate = taxRates.find((rate) => rate.id === invoiceForm.tax_rate_id);
      const invoiceNumber = invoiceForm.invoice_number.trim();
      const subtotal = Number(invoiceForm.subtotal);
      const { data: invoice, error } = await supabase.from("books_invoices").insert({ organization_id: organizationId, invoice_number: invoiceNumber, contact_id: invoiceForm.contact_id || null, issue_date: invoiceForm.issue_date, due_date: invoiceForm.due_date, currency_code: currency, subtotal, tax_rate_id: invoiceForm.tax_rate_id || null, tax_rate_percentage: selectedRate?.rate_percentage || 0, status: "draft" }).select("id").single();
      if (error || !invoice) {
        reportBooksError(operation, correlationId, organizationId, null, error || { message: "Invoice was not returned after creation" });
        toast(operationToast("Could not save invoice", correlationId));
        return;
      }
      const { error: lineError } = await supabase.from("books_invoice_lines").insert({ invoice_id: invoice.id, organization_id: organizationId, description: `Invoice ${invoiceNumber}`, quantity: 1, unit_price: subtotal });
      if (lineError) {
        reportBooksError(operation, correlationId, organizationId, invoice.id, lineError);
        await supabase.from("books_invoices").delete().eq("id", invoice.id).eq("organization_id", organizationId);
        toast(operationToast("Could not save invoice line", correlationId));
        return;
      }
      setInvoiceForm({ invoice_number: "", contact_id: "", issue_date: today, due_date: today, subtotal: "", tax_rate_id: "" });
      toast({ title: "Invoice saved", description: "The invoice is ready to review and send." });
      await loadBooks();
    } catch (error) {
      reportBooksError(operation, correlationId, organizationId, null, error as SupabaseErrorLike);
      toast(operationToast("Could not save invoice", correlationId));
    } finally {
      setSaving(false);
    }
  };

  const saveExpense = async (event: FormEvent) => {
    event.preventDefault();
    if (!organizationId || !expenseForm.description.trim() || !expenseForm.amount) return;
    const operation: BooksOperation = "books.expense.save";
    const correlationId = newCorrelationId();
    setSaving(true);
    try {
      const { error } = await supabase.from("books_expenses").insert({ organization_id: organizationId, description: expenseForm.description.trim(), contact_id: expenseForm.contact_id || null, expense_date: expenseForm.expense_date, currency_code: currency, amount: Number(expenseForm.amount), tax_amount: Number(expenseForm.tax_amount || 0), payment_status: "paid" });
      if (error) {
        reportBooksError(operation, correlationId, organizationId, null, error);
        toast(operationToast("Could not save expense", correlationId));
        return;
      }
      setExpenseForm({ description: "", contact_id: "", expense_date: today, amount: "", tax_amount: "" });
      toast({ title: "Expense recorded" });
      await loadBooks();
    } catch (error) {
      reportBooksError(operation, correlationId, organizationId, null, error as SupabaseErrorLike);
      toast(operationToast("Could not save expense", correlationId));
    } finally {
      setSaving(false);
    }
  };

  const markLatestInvoicePaid = async () => {
    const invoice = visibleInvoices.find((item) => item.status !== "paid" && item.status !== "void");
    if (!invoice || !organizationId) {
      toast({ title: "All invoices are already paid", description: "Create a new draft invoice to test the paid-invoice workflow." });
      return;
    }
    const operation: BooksOperation = "books.invoice.markPaid";
    const correlationId = newCorrelationId();
    setSaving(true);
    try {
      const { error } = await supabase.from("books_invoices").update({ status: "paid" }).eq("id", invoice.id).eq("organization_id", organizationId);
      if (error) {
        reportBooksError(operation, correlationId, organizationId, invoice.id, error);
        toast(operationToast("Could not mark invoice paid", correlationId));
        return;
      }
      toast({ title: "Invoice marked paid", description: "The ledger trigger and paid-invoice webhook can now process it." });
      await loadBooks();
    } catch (error) {
      reportBooksError(operation, correlationId, organizationId, invoice.id, error as SupabaseErrorLike);
      toast(operationToast("Could not mark invoice paid", correlationId));
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <div className="min-h-screen bg-sheraton-cream/30 p-8"><div className="mx-auto max-w-7xl animate-pulse space-y-6"><div className="h-12 rounded bg-muted" /><div className="h-40 rounded bg-muted" /><div className="h-64 rounded bg-muted" /></div></div>;

  return (
    <div className="min-h-screen bg-gradient-to-b from-sheraton-cream/70 to-background">
      <div className="container max-w-7xl py-8">
        <div className="mb-8 flex flex-col justify-between gap-4 md:flex-row md:items-end">
          <div><div className="mb-3 flex items-center gap-2"><BookOpen className="h-7 w-7 text-sheraton-gold" /><Badge className="bg-sheraton-gold text-sheraton-navy">Books</Badge></div><h1 className="text-4xl font-bold text-sheraton-navy">{isConsolidatedView ? "Consolidated financials" : isUsdView ? "USD Books" : "Your business finances"}</h1><p className="mt-2 max-w-2xl text-muted-foreground">One secure Books workspace, with same-currency accounting views and transparent conversions using stored reference exchange rates.</p></div>
          <div className="flex gap-2"><Button variant="outline" onClick={() => void loadBooks()}><RefreshCw className="mr-2 h-4 w-4" />Refresh</Button><Button variant="outline" onClick={() => void markLatestInvoicePaid()} disabled={saving || openInvoices.length === 0}>{openInvoices.length ? "Mark open invoice paid" : "All invoices paid"}</Button></div>
          {isConsolidatedView && <Card className="w-full"><CardContent className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"><div><p className="font-semibold">Convert consolidated totals</p><p className="text-xs text-muted-foreground">Reference rate · open.er-api.com · {fxAsOf ? `source timestamp ${new Date(fxAsOf).toLocaleString()}` : "rates loading"}</p></div><div className="flex gap-2"><select aria-label="Converted reporting currency" className="h-10 rounded-md border border-input bg-background px-3 text-sm" value={targetCurrency} onChange={(event) => setTargetCurrency(event.target.value)}>{supportedCurrencies.map((code) => <option key={code} value={code}>{code}</option>)}</select><Button type="button" variant="outline" onClick={() => void refreshExchangeRates()}><RefreshCw className="mr-2 h-4 w-4" />Refresh rates</Button></div>{fxError && <p role="alert" className="text-sm text-destructive">{fxError}</p>}</CardContent></Card>}
        </div>
        <Tabs value={activeTab} onValueChange={setActiveTab} className="space-y-6">
          <TabsList className="grid h-auto w-full grid-cols-2 gap-1 md:grid-cols-6"><TabsTrigger value="overview">Overview</TabsTrigger><TabsTrigger value="contacts">Contacts</TabsTrigger><TabsTrigger value="invoices">Invoices</TabsTrigger><TabsTrigger value="expenses">Expenses</TabsTrigger><TabsTrigger value="reports">Reports</TabsTrigger><TabsTrigger value="accounts">Chart of accounts</TabsTrigger></TabsList>
          <TabsContent value="overview" className="space-y-6">
            {isConsolidatedView ? <><div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4"><Metric label={`Income · ${targetCurrency}`} value={hasAllConversionRates ? formatMoney(convertTotal("income"), targetCurrency) : "Rates unavailable"} icon={<ArrowUpRight className="h-5 w-5" />} tone="green" /><Metric label={`Expenses · ${targetCurrency}`} value={hasAllConversionRates ? formatMoney(convertTotal("expenses"), targetCurrency) : "Rates unavailable"} icon={<ArrowDownToLine className="h-5 w-5" />} tone="red" /><Metric label={`Receivables · ${targetCurrency}`} value={hasAllConversionRates ? formatMoney(convertTotal("receivables"), targetCurrency) : "Rates unavailable"} icon={<CircleDollarSign className="h-5 w-5" />} tone="gold" /><Metric label={`Net result · ${targetCurrency}`} value={hasAllConversionRates ? formatMoney(convertTotal("net_result"), targetCurrency) : "Rates unavailable"} icon={<BarChart3 className="h-5 w-5" />} tone="green" /></div><Card><CardHeader><CardTitle>Totals by source currency</CardTitle><p className="text-sm text-muted-foreground">Values are stored in their original currency. Converted totals use the latest available public reference rate and are informational estimates, not transaction rates or posted accounting values.</p></CardHeader><CardContent><DataTable headers={["Currency", "Invoices", "Tax + levies", "Expenses", "Net result", `Net in ${targetCurrency}`]}>{currencyTotals.map((row) => { const factor = fxFactor(row.currency_code); return <tr key={row.currency_code} className="border-b"><td className="p-4 font-semibold">{row.currency_code}</td><td className="p-4">{formatMoney(Number(row.invoice_total), row.currency_code)}</td><td className="p-4">{formatMoney(Number(row.tax_total), row.currency_code)}</td><td className="p-4">{formatMoney(Number(row.expenses), row.currency_code)}</td><td className="p-4">{formatMoney(Number(row.net_result), row.currency_code)}</td><td className="p-4">{factor === null ? "Rate unavailable" : formatMoney(Number(row.net_result) * factor, targetCurrency)}</td></tr>; })}</DataTable><div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{([["Total invoices", "invoice_total"], ["Tax + levies", "tax_total"], ["Assets", "assets"], ["Liabilities", "liabilities"]] as const).map(([label, field]) => <div key={field} className="rounded-lg border p-3"><p className="text-xs text-muted-foreground">{label} · {targetCurrency}</p><p className="mt-1 font-semibold">{hasAllConversionRates ? formatMoney(convertTotal(field), targetCurrency) : "Rates unavailable"}</p></div>)}</div></CardContent></Card></> : <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4"><Metric label={`Income · ${currency}`} value={formatMoney(revenue, currency)} icon={<ArrowUpRight className="h-5 w-5" />} tone="green" /><Metric label={`Expenses · ${currency}`} value={formatMoney(expensesTotal, currency)} icon={<ArrowDownToLine className="h-5 w-5" />} tone="red" /><Metric label={`Receivables · ${currency}`} value={formatMoney(receivable, currency)} icon={<CircleDollarSign className="h-5 w-5" />} tone="gold" /><Metric label={`Net result · ${currency}`} value={formatMoney(profit, currency)} icon={<BarChart3 className="h-5 w-5" />} tone={profit >= 0 ? "green" : "red"} /></div>}
            <div className="grid gap-6 lg:grid-cols-[1.3fr_.7fr]"><Card><CardHeader><CardTitle>Get started</CardTitle></CardHeader><CardContent className="grid gap-3 sm:grid-cols-3"><QuickAction icon={<Users />} title="Add a contact" text="Customers and vendors" onClick={() => setActiveTab("contacts")} /><QuickAction icon={<FileText />} title="Create an invoice" text="Track money owed" onClick={() => setActiveTab("invoices")} /><QuickAction icon={<Receipt />} title="Record an expense" text="Keep costs current" onClick={() => setActiveTab("expenses")} /></CardContent></Card><Card><CardHeader><CardTitle>Attention needed</CardTitle></CardHeader><CardContent className="space-y-3 text-sm"><p>{overdue ? `${overdue} invoice${overdue === 1 ? "" : "s"} need follow-up.` : "No overdue invoices."}</p><p>{customerContacts.length} customer contacts and {vendorContacts.length} vendors are in your books.</p><Button variant="link" className="px-0" onClick={() => setActiveTab("reports")}>View financial reports →</Button></CardContent></Card></div>
            {loyaltyPostings.length > 0 && <Card><CardHeader><CardTitle>Rewards liability postings</CardTitle><p className="text-sm text-muted-foreground">Platform-funded loyalty accruals and reversals recorded in this Books organization.</p></CardHeader><CardContent><DataTable headers={["Posted date", "Amount (UGX)", "Status", "Journal"]}>{loyaltyPostings.map((posting) => <tr key={posting.ledger_entry_id} className="border-b"><td className="p-4">{new Date(posting.created_at).toLocaleDateString()}</td><td className="p-4">{formatMoney(Number(posting.amount_ugx), "UGX")}</td><td className="p-4"><Badge variant={posting.status === "posted" ? "default" : "outline"}>{posting.status}</Badge>{posting.status === "failed" && posting.error_message && <p className="mt-1 text-xs text-destructive">{posting.error_message}</p>}</td><td className="p-4 font-mono text-xs">{posting.journal_transaction_id || "Pending"}</td></tr>)}</DataTable></CardContent></Card>}
          </TabsContent>
          <TabsContent value="contacts" className="space-y-6"><Card><CardHeader><CardTitle>Add customer or vendor</CardTitle></CardHeader><CardContent><form onSubmit={saveContact} className="grid gap-4 md:grid-cols-5"><div className="space-y-2 md:col-span-2"><Label>Name *</Label><Input value={contactForm.name} onChange={(event) => setContactForm({ ...contactForm, name: event.target.value })} placeholder="Business or person" required /></div><div className="space-y-2"><Label>Type</Label><select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={contactForm.type} onChange={(event) => setContactForm({ ...contactForm, type: event.target.value as Contact["type"] })}><option value="customer">Customer</option><option value="vendor">Vendor</option><option value="both">Both</option></select></div><div className="space-y-2"><Label>Email</Label><Input type="email" value={contactForm.email} onChange={(event) => setContactForm({ ...contactForm, email: event.target.value })} /></div><div className="flex items-end"><Button className="w-full sheraton-gradient text-white" disabled={saving}><Plus className="mr-2 h-4 w-4" />Add contact</Button></div></form></CardContent></Card><DataTable headers={["Name", "Type", "Email", "Tax ID"]}>{contacts.map((contact) => <tr key={contact.id} className="border-b"><td className="p-4 font-medium">{contact.name}</td><td className="p-4"><Badge variant="outline">{contact.type}</Badge></td><td className="p-4 text-muted-foreground">{contact.email || "—"}</td><td className="p-4 text-muted-foreground">{contact.tax_id || "—"}</td></tr>)}</DataTable></TabsContent>
          <TabsContent value="invoices" className="space-y-6"><EntryCard title="Create invoice" onSubmit={saveInvoice} saving={saving}><div className="grid gap-4 md:grid-cols-6"><Field label="Invoice number"><Input value={invoiceForm.invoice_number} onChange={(event) => setInvoiceForm({ ...invoiceForm, invoice_number: event.target.value })} placeholder="INV-0001" required /></Field><Field label="Customer"><select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={invoiceForm.contact_id} onChange={(event) => setInvoiceForm({ ...invoiceForm, contact_id: event.target.value })}><option value="">Select customer</option>{customerContacts.map((contact) => <option key={contact.id} value={contact.id}>{contact.name}</option>)}</select></Field><Field label="Issue date"><Input type="date" value={invoiceForm.issue_date} onChange={(event) => setInvoiceForm({ ...invoiceForm, issue_date: event.target.value })} /></Field><Field label="Due date"><Input type="date" value={invoiceForm.due_date} onChange={(event) => setInvoiceForm({ ...invoiceForm, due_date: event.target.value })} /></Field><Field label={`Subtotal (${currency})`}><Input type="number" min="0" step="0.01" value={invoiceForm.subtotal} onChange={(event) => setInvoiceForm({ ...invoiceForm, subtotal: event.target.value })} required /></Field><Field label="Tax rate"><select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={invoiceForm.tax_rate_id} onChange={(event) => setInvoiceForm({ ...invoiceForm, tax_rate_id: event.target.value })}><option value="">No tax</option>{taxRates.map((rate) => <option key={rate.id} value={rate.id}>{rate.name} ({rate.rate_percentage}%)</option>)}</select></Field></div></EntryCard><DataTable headers={["Invoice", "Customer", "Issue date", "Due date", "Total", "Status"]}>{visibleInvoices.map((invoice) => <tr key={invoice.id} className="border-b"><td className="p-4 font-medium">{invoice.invoice_number}</td><td className="p-4">{contactName(invoice.contact_id)}</td><td className="p-4">{invoice.issue_date}</td><td className="p-4">{invoice.due_date}</td><td className="p-4 font-semibold">{formatMoney(Number(invoice.total_due), invoice.currency_code.trim())}</td><td className="p-4"><Badge variant={invoice.status === "paid" ? "default" : "outline"}>{invoice.status}</Badge></td></tr>)}</DataTable></TabsContent>
          <TabsContent value="expenses" className="space-y-6"><EntryCard title="Record expense" onSubmit={saveExpense} saving={saving}><div className="grid gap-4 md:grid-cols-5"><Field label="Description"><Input value={expenseForm.description} onChange={(event) => setExpenseForm({ ...expenseForm, description: event.target.value })} placeholder="Internet, rent, supplies" required /></Field><Field label="Vendor"><select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={expenseForm.contact_id} onChange={(event) => setExpenseForm({ ...expenseForm, contact_id: event.target.value })}><option value="">Select vendor</option>{vendorContacts.map((contact) => <option key={contact.id} value={contact.id}>{contact.name}</option>)}</select></Field><Field label="Date"><Input type="date" value={expenseForm.expense_date} onChange={(event) => setExpenseForm({ ...expenseForm, expense_date: event.target.value })} /></Field><Field label={`Amount (${currency})`}><Input type="number" min="0" step="0.01" value={expenseForm.amount} onChange={(event) => setExpenseForm({ ...expenseForm, amount: event.target.value })} required /></Field><Field label={`Tax (${currency})`}><Input type="number" min="0" step="0.01" value={expenseForm.tax_amount} onChange={(event) => setExpenseForm({ ...expenseForm, tax_amount: event.target.value })} /></Field></div></EntryCard><DataTable headers={["Description", "Vendor", "Date", "Amount", "Payment"]}>{visibleExpenses.map((expense) => <tr key={expense.id} className="border-b"><td className="p-4 font-medium">{expense.description}</td><td className="p-4">{contactName(expense.contact_id)}</td><td className="p-4">{expense.expense_date}</td><td className="p-4 font-semibold">{formatMoney(Number(expense.amount) + Number(expense.tax_amount), expense.currency_code.trim())}</td><td className="p-4"><Badge variant="outline">{expense.payment_status}</Badge></td></tr>)}</DataTable></TabsContent>
          <TabsContent value="reports" className="space-y-6">{isConsolidatedView ? <Card><CardHeader><CardTitle>Converted financial statements · {targetCurrency}</CardTitle><p className="text-sm text-muted-foreground">Source amounts remain unchanged in Books. Conversion uses the latest available public reference rate, which may differ from a bank or payment provider’s transaction rate, and is never used to alter accounting entries.</p></CardHeader><CardContent><DataTable headers={["Statement measure", `Converted total (${targetCurrency})`]}>{([["Invoice total", "invoice_total"], ["Income", "income"], ["Expenses", "expenses"], ["Net result", "net_result"], ["Tax and hotel levies", "tax_total"], ["Receivables", "receivables"], ["Assets", "assets"], ["Liabilities", "liabilities"], ["Equity", "equity"]] as const).map(([label, field]) => <tr key={field} className="border-b"><td className="p-4">{label}</td><td className="p-4 font-semibold">{hasAllConversionRates ? formatMoney(convertTotal(field), targetCurrency) : "Rates unavailable"}</td></tr>)}</DataTable></CardContent></Card> : <><div className="grid gap-6 lg:grid-cols-3"><ReportCard title="Profit & loss" rows={[["Income", revenue], ["Expenses", expensesTotal], ["Net result", profit]]} currency={currency} /><ReportCard title="Balance sheet" rows={[["Assets", assets], ["Liabilities", liabilities], ["Equity", equity]]} currency={currency} /><ReportCard title="Receivables" rows={[["Open invoices", receivable], ["Paid invoices", visibleInvoices.filter((invoice) => invoice.status === "paid").reduce((sum, invoice) => sum + Number(invoice.total_due), 0)]]} currency={currency} /></div><Card><CardHeader><CardTitle>Ledger-backed reporting</CardTitle></CardHeader><CardContent className="text-sm text-muted-foreground">Reports are calculated from immutable journal lines created automatically when expenses are recorded and invoices are paid. The balance sheet follows Assets = Liabilities + Equity.</CardContent></Card></>}</TabsContent>
          <TabsContent value="accounts"><Card><CardHeader><CardTitle>Chart of accounts</CardTitle></CardHeader><CardContent>{accounts.length ? <DataTable headers={["Code", "Account", "Type"]}>{accounts.map((account) => <tr key={account.id} className="border-b"><td className="p-4 font-mono">{account.code}</td><td className="p-4 font-medium">{account.name}</td><td className="p-4"><Badge variant="outline">{account.type}</Badge></td></tr>)}</DataTable> : <div className="rounded-lg border border-dashed p-8 text-center text-muted-foreground">Your chart of accounts will appear here once your Books workspace is initialized.</div>}</CardContent></Card></TabsContent>
        </Tabs>
      </div>
    </div>
  );
};

const Metric = ({ label, value, icon, tone }: { label: string; value: string; icon: React.ReactNode; tone: "green" | "red" | "gold" }) => <Card><CardContent className="flex items-center justify-between p-5"><div><p className="text-sm text-muted-foreground">{label}</p><p className="mt-1 text-2xl font-bold text-sheraton-navy">{value}</p></div><span className={`rounded-full p-3 ${tone === "green" ? "bg-green-100 text-green-700" : tone === "red" ? "bg-red-100 text-red-700" : "bg-sheraton-gold/20 text-sheraton-gold"}`}>{icon}</span></CardContent></Card>;
const QuickAction = ({ icon, title, text, onClick }: { icon: React.ReactNode; title: string; text: string; onClick: () => void }) => <button onClick={onClick} className="rounded-lg border p-4 text-left transition-colors hover:bg-muted"><span className="mb-3 block text-sheraton-gold">{icon}</span><span className="block font-semibold">{title}</span><span className="text-sm text-muted-foreground">{text}</span></button>;
const Field = ({ label, children }: { label: string; children: React.ReactNode }) => <div className="space-y-2"><Label>{label}</Label>{children}</div>;
const EntryCard = ({ title, onSubmit, saving, children }: { title: string; onSubmit: (event: FormEvent) => void; saving: boolean; children: React.ReactNode }) => <Card><CardHeader><CardTitle>{title}</CardTitle></CardHeader><CardContent><form onSubmit={onSubmit} className="space-y-4">{children}<Button className="sheraton-gradient text-white" disabled={saving}><Plus className="mr-2 h-4 w-4" />{saving ? "Saving…" : "Save"}</Button></form></CardContent></Card>;
const DataTable = ({ headers, children }: { headers: string[]; children: React.ReactNode }) => <Card><CardContent className="p-0"><div className="overflow-x-auto"><table className="w-full min-w-[650px]"><thead><tr className="border-b bg-muted/30">{headers.map((header) => <th key={header} className="p-4 text-left text-sm font-semibold">{header}</th>)}</tr></thead><tbody>{children}</tbody></table></div></CardContent></Card>;
const ReportCard = ({ title, rows, currency }: { title: string; rows: [string, number][]; currency: string }) => <Card><CardHeader><CardTitle className="text-lg">{title}</CardTitle></CardHeader><CardContent className="space-y-3">{rows.map(([label, value]) => <div key={label} className="flex justify-between border-b pb-2 text-sm last:border-0"><span className="text-muted-foreground">{label}</span><span className="font-semibold">{formatMoney(value, currency)}</span></div>)}</CardContent></Card>;

export default BooksPage;
