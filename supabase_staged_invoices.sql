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
  target_user_id TEXT,
  target_user_email TEXT,
  target_user_name TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Safe non-destructive column migrations:
ALTER TABLE public.staged_invoices ADD COLUMN IF NOT EXISTS target_user_id TEXT;
ALTER TABLE public.staged_invoices ADD COLUMN IF NOT EXISTS target_user_email TEXT;
ALTER TABLE public.staged_invoices ADD COLUMN IF NOT EXISTS target_user_name TEXT;
ALTER TABLE public.staged_invoices ADD COLUMN IF NOT EXISTS receipt_photos JSONB DEFAULT '[]'::jsonb;

-- Enable Row Level Security (RLS)
ALTER TABLE public.staged_invoices ENABLE ROW LEVEL SECURITY;

-- Idempotent RLS policies (Created safely without DROP commands)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'public' 
      AND tablename = 'staged_invoices' 
      AND policyname = 'Allow public read of staged_invoices'
  ) THEN
    CREATE POLICY "Allow public read of staged_invoices" 
      ON public.staged_invoices 
      FOR SELECT 
      USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'public' 
      AND tablename = 'staged_invoices' 
      AND policyname = 'Allow public insert of staged_invoices'
  ) THEN
    CREATE POLICY "Allow public insert of staged_invoices" 
      ON public.staged_invoices 
      FOR INSERT 
      WITH CHECK (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname = 'public' 
      AND tablename = 'staged_invoices' 
      AND policyname = 'Allow update of staged_invoices'
  ) THEN
    CREATE POLICY "Allow update of staged_invoices" 
      ON public.staged_invoices 
      FOR UPDATE 
      USING (true) 
      WITH CHECK (true);
  END IF;
END
$$;

-- Indexes for speedy queries and multi-user isolation
CREATE INDEX IF NOT EXISTS idx_staged_invoices_status ON public.staged_invoices(status);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_created ON public.staged_invoices(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_target_uid ON public.staged_invoices(target_user_id);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_target_email ON public.staged_invoices(target_user_email);
