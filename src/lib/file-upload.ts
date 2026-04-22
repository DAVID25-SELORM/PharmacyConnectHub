export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

function fileNameToJpeg(name: string) {
  return name.replace(/\.[^.]+$/, "") || "upload";
}

function loadImage(file: File) {
  return new Promise<HTMLImageElement>((resolve, reject) => {
    const image = new Image();
    const objectUrl = URL.createObjectURL(file);

    image.onload = () => {
      URL.revokeObjectURL(objectUrl);
      resolve(image);
    };

    image.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      reject(new Error("Unable to read the selected image"));
    };

    image.src = objectUrl;
  });
}

function canvasToBlob(canvas: HTMLCanvasElement, quality: number) {
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (!blob) {
          reject(new Error("Unable to prepare the image for upload"));
          return;
        }

        resolve(blob);
      },
      "image/jpeg",
      quality,
    );
  });
}

export async function compressImageForUpload(file: File, maxBytes = MAX_UPLOAD_BYTES) {
  const image = await loadImage(file);
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d");

  if (!context) {
    throw new Error("Image uploads are not supported in this browser");
  }

  let quality = 0.82;
  let scale = Math.min(1, 1600 / Math.max(image.naturalWidth, image.naturalHeight));
  let blob: Blob | null = null;

  for (let attempt = 0; attempt < 6; attempt += 1) {
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);

    blob = await canvasToBlob(canvas, quality);

    if (blob.size <= maxBytes) {
      break;
    }

    if (quality > 0.5) {
      quality -= 0.12;
    } else {
      scale *= 0.82;
    }
  }

  if (!blob || blob.size > maxBytes) {
    throw new Error("Image is still larger than 10MB after compression");
  }

  return new File([blob], `${fileNameToJpeg(file.name)}.jpg`, {
    type: "image/jpeg",
    lastModified: Date.now(),
  });
}

export function formatFileSize(bytes: number) {
  if (bytes < 1024 * 1024) {
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }

  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
