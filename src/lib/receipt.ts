import { supabase } from './supabase';

/** Shrinks a phone photo to at most 1600 px on the long side as JPEG, saving mobile data. PDFs pass through. */
async function shrink(file: File): Promise<Blob> {
  if (!file.type.startsWith('image/') || file.size < 400_000) return file;
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bmp.width * scale); canvas.height = Math.round(bmp.height * scale);
    canvas.getContext('2d')!.drawImage(bmp, 0, 0, canvas.width, canvas.height);
    return await new Promise<Blob>((res, rej) => canvas.toBlob(b => (b ? res(b) : rej(new Error('Could not compress'))), 'image/jpeg', 0.8));
  } catch { return file; }
}

/** Uploads a receipt to the private "receipts" bucket under the user's own folder. Returns the storage path. */
export async function uploadReceipt(file: File, userId: string) {
  const blob = await shrink(file);
  const ext = blob.type === 'application/pdf' ? 'pdf' : 'jpg';
  const path = `${userId}/${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage.from('receipts').upload(path, blob, { contentType: blob.type || 'image/jpeg' });
  if (error) throw new Error('Receipt upload failed: ' + error.message);
  return path;
}

export async function receiptUrl(path: string) {
  const { data, error } = await supabase.storage.from('receipts').createSignedUrl(path, 600);
  if (error) throw new Error(error.message);
  return data.signedUrl;
}
