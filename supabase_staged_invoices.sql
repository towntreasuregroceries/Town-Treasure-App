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
ALTER TABLE public.staged_invoices ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Enable Row Level Security (RLS)
ALTER TABLE public.staged_invoices ENABLE ROW LEVEL SECURITY;

-- Do not add public/anon RLS policies here. Apply
-- supabase_clerk_invite_security.sql after deploying the clerk-api Edge
-- Function to enable authenticated owner access and verified invite actions.

-- Indexes for speedy queries and multi-user isolation
CREATE INDEX IF NOT EXISTS idx_staged_invoices_status ON public.staged_invoices(status);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_created ON public.staged_invoices(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_target_uid ON public.staged_invoices(target_user_id);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_target_email ON public.staged_invoices(target_user_email);
