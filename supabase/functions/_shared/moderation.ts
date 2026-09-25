// Photo moderation with AWS Rekognition DetectModerationLabels (image bytes, no S3 needed).
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

/** Verdict for a JPEG/PNG up to 5 MB. `review` leaves the media pending for a human. */
export async function moderateImage(bytes: Uint8Array): Promise<{ verdict: Verdict; labels: string[] }> {
  const region = optionalEnv("AWS_REGION") ?? "eu-west-1";
  const res = await client().fetch(`https://rekognition.${region}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-target": "RekognitionService.DetectModerationLabels",
    },
    body: JSON.stringify({ Image: { Bytes: toBase64(bytes) }, MinConfidence: 60 }),
  });
  if (!res.ok) throw new Error(`Rekognition ${res.status}: ${await res.text()}`);
  const { ModerationLabels } = await res.json() as { ModerationLabels: Label[] };

  const names = ModerationLabels.flatMap((l) => [l.Name, l.ParentName]).filter(Boolean);
  const labels = ModerationLabels.map((l) => `${l.Name} ${Math.round(l.Confidence)}%`);
  if (names.some((n) => REJECT.has(n))) return { verdict: "rejected", labels };
  if (names.some((n) => REVIEW.has(n))) return { verdict: "review", labels };
  return { verdict: "approved", labels };
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}
