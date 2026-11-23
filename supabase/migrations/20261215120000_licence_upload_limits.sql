-- The private "licenses" bucket (licence and registration documents) had no server-side limits:
-- any file type of any size was accepted by the storage API. The evidence buckets already
-- restrict type and size; this brings licences in line. The app also checks the real content
-- of each file before uploading (src/lib/upload-safety.ts).
--
-- Existing files are not touched; the limits apply to new uploads only.
UPDATE storage.buckets
SET file_size_limit = 10485760,
    allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
WHERE id = 'licenses';
