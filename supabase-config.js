const supabaseUrl = 'https://bulptzqaoddnptiwfrce.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1bHB0enFhb2RkbnB0aXdmcmNlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MzE5ODgsImV4cCI6MjA5MzEwNzk4OH0.XHM5Xa3dqOAL5bU4AbATuu9xTVFnkX8BB8_joIFdfKM';

// Initialize the Supabase client
const supabaseClient = window.supabase ? window.supabase.createClient(supabaseUrl, supabaseKey) : null;
