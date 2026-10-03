-- ══════════════════════════════════════════════════════════════════
-- Town Treasure Groceries — Staged Invoices Table Setup
-- Run this in your Supabase SQL Editor (https://supabase.com/dashboard)
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.staged_invoices (
  id TEXT PRIMARY KEY,
  clerk_name TEXT NOT NULL DEFAULT 'Clerk',
  restaurant_name TEXT NOT NULL DEFAULT 'General Wholesale',
  invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
  items_json JSONB NOT NULL DEFAULT '[]'::jsonb,
  delivery_cost NUMERIC DEFAULT 0,
  other_cost NUMERIC DEFAULT 0,
  total_sell NUMERIC DEFAULT 0,
  total_buy NUMERIC DEFAULT 0,
  receipt_photo TEXT,
  receipt_photos JSONB DEFAULT '[]'::jsonb,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable Row Level Security (RLS)
ALTER TABLE public.staged_invoices ENABLE ROW LEVEL SECURITY;

-- Allow anon clerks to insert & read staged submissions without needing full vault login
CREATE POLICY "Allow public read of staged_invoices" 
  ON public.staged_invoices 
  FOR SELECT 
  USING (true);

CREATE POLICY "Allow public insert of staged_invoices" 
  ON public.staged_invoices 
  FOR INSERT 
  WITH CHECK (true);

CREATE POLICY "Allow update of staged_invoices" 
  ON public.staged_invoices 
  FOR UPDATE 
  USING (true) 
  WITH CHECK (true);

-- Index for speedy pending queries
CREATE INDEX IF NOT EXISTS idx_staged_invoices_status ON public.staged_invoices(status);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_created ON public.staged_invoices(created_at DESC);
