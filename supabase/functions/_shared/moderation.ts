// Photo moderation with AWS Rekognition DetectModerationLabels (image bytes, no S3 needed), and the face
// check that decides which photo may be a portrait (DetectFaces).
// Videos are judged on their poster frame; full video analysis is a TODO.
import { AwsClient } from "npm:aws4fetch@1";
import { env, optionalEnv } from "./env.ts";

export type Verdict = "approved" | "rejected" | "review";

interface Label {
  Name: string;
  ParentName: string;
  Confidence: number;
}

// Rekognition taxonomy v7. Labels are matched on their own name and their parent's, across levels.
// Swimwear is allowed on purpose (swimmers, surfers, triathletes), and weapons only go to review
// (archery, fencing).
const REJECT = new Set([
  "Explicit",
  "Explicit Nudity",
  "Explicit Sexual Activity",
  "Sex Toys",
  "Graphic Violence",
  "Visually Disturbing",
  "Hate Symbols",
]);
const REVIEW = new Set([
  "Non-Explicit Nudity of Intimate parts and Kissing",
  "Violence",
  "Weapons",
  "Drugs & Tobacco",
  "Rude Gestures",
]);

let aws: AwsClient | undefined;

function client(): AwsClient {
  aws ??= new AwsClient({
    accessKeyId: env("AWS_REKOGNITION_ACCESS_KEY_ID"),
    secretAccessKey: env("AWS_REKOGNITION_SECRET_ACCESS_KEY"),
    service: "rekognition",
    region: optionalEnv("AWS_REGION") ?? "eu-west-1",
  });
  return aws;
}

export function moderationConfigured(): boolean {
  return Boolean(optionalEnv("AWS_REKOGNITION_ACCESS_KEY_ID"));
}

async function rekognition<T>(action: string, body: unknown): Promise<T> {
  const region = optionalEnv("AWS_REGION") ?? "eu-west-1";
  const res = await client().fetch(`https://rekognition.${region}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-target": `RekognitionService.${action}`,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Rekognition ${action} ${res.status}: ${await res.text()}`);
  return await res.json() as T;
}

/** Verdict for a JPEG/PNG up to 5 MB. `review` leaves the media pending for a human. */
export async function moderateImage(bytes: Uint8Array): Promise<{ verdict: Verdict; labels: string[] }> {
  const { ModerationLabels } = await rekognition<{ ModerationLabels: Label[] }>("DetectModerationLabels", {
    Image: { Bytes: toBase64(bytes) },
    MinConfidence: 60,
  });

  const names = ModerationLabels.flatMap((l) => [l.Name, l.ParentName]).filter(Boolean);
  const labels = ModerationLabels.map((l) => `${l.Name} ${Math.round(l.Confidence)}%`);
  if (names.some((n) => REJECT.has(n))) return { verdict: "rejected", labels };
  if (names.some((n) => REVIEW.has(n))) return { verdict: "review", labels };
  return { verdict: "approved", labels };
}

export interface FaceBox {
  Confidence: number;
  BoundingBox: { Width: number; Height: number };
}

/** A face someone could recognise: surely a face, and at least 2% of the frame (the app's own check). */
export function recognisable(faces: FaceBox[]): boolean {
  return faces.some((f) => f.Confidence >= 90 && f.BoundingBox.Width * f.BoundingBox.Height >= 0.02);
}

/** Whether a JPEG/PNG up to 5 MB shows a recognisable face: only such a photo may be the portrait. */
export async function hasFace(bytes: Uint8Array): Promise<boolean> {
  const { FaceDetails } = await rekognition<{ FaceDetails: FaceBox[] }>("DetectFaces", {
    Image: { Bytes: toBase64(bytes) },
  });
  return recognisable(FaceDetails ?? []);
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}
