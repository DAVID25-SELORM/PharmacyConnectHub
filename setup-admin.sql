-- Setup script for your admin account
-- Run this in Supabase Dashboard → SQL Editor

-- STEP 1: Find your user ID (replace 'your-email@example.com' with your actual email)
DO $$
DECLARE
  v_user_id UUID;
  v_business_id UUID;
BEGIN
  -- Get the user ID for your email
  SELECT id INTO v_user_id
  FROM auth.users
  WHERE email = 'gabiondavidselorm@gmail.com'
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found. Make sure the email is correct.';
  END IF;

  RAISE NOTICE 'Found user ID: %', v_user_id;

  -- STEP 2: Create a business record (pharmacy or wholesaler)
  INSERT INTO public.businesses (
    owner_id,
    type,
    name,
    license_number,
    city,
    region,
    phone,
    verification_status,  -- Set to 'approved' to skip verification
    verified_at
  ) VALUES (
    v_user_id,
    'pharmacy',
    'PharmaHub Admin',
    'PCG-ADMIN-001',
    'Accra',
    'Greater Accra',
    '0247654381',
    'approved',  -- Skip verification process
    now()
  )
  RETURNING id INTO v_business_id;

  RAISE NOTICE 'Created business ID: %', v_business_id;

  -- STEP 3: Grant admin role (optional - uncomment if you want full admin access)
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_user_id, 'admin')
  ON CONFLICT (user_id, role) DO NOTHING;

  RAISE NOTICE 'Admin role granted to user %', v_user_id;

  -- STEP 4: Update profile with name and phone
  UPDATE public.profiles
  SET 
    full_name = 'David Selorm Gabion',
    phone = '0247654381'
  WHERE id = v_user_id;

  RAISE NOTICE 'Profile updated successfully';
  RAISE NOTICE '✓ Setup complete! You can now sign in to the app.';

END $$;
