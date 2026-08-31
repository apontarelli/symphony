import { rename, writeFile } from "node:fs/promises";

interface Usage {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	totalTokens: number;
}

interface AssistantMessage {
	role: string;
	usage?: Usage;
}

interface MessageEndEvent {
	message: AssistantMessage;
}

interface ExtensionApi {
	pi: { VERSION: string };
	on(event: "session_start", handler: () => Promise<void>): void;
	on(event: "message_end", handler: (event: MessageEndEvent) => Promise<void>): void;
	on(event: "session_shutdown", handler: () => Promise<void>): void;
}

const telemetryPath = process.env.SYMPHONY_OMP_TOKEN_TELEMETRY_PATH;

function tokenCount(value: unknown): number | undefined {
	return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

export default function tokenTelemetry(api: ExtensionApi): void {
	if (!telemetryPath) return;

	let sequence = 0;
	let inputTokens = 0;
	let outputTokens = 0;
	let totalTokens = 0;
	let pendingWrite = Promise.resolve();

	const publish = (): Promise<void> => {
		const snapshot = `${JSON.stringify({
			schema_version: 1,
			omp_version: api.pi.VERSION,
			sequence,
			input_tokens: inputTokens,
			output_tokens: outputTokens,
			total_tokens: totalTokens,
		})}\n`;
		const temporaryPath = `${telemetryPath}.${process.pid}.tmp`;

		pendingWrite = pendingWrite.then(async () => {
			await writeFile(temporaryPath, snapshot, { encoding: "utf8", mode: 0o600 });
			await rename(temporaryPath, telemetryPath);
		});

		return pendingWrite;
	};

	api.on("session_start", publish);

	api.on("message_end", async event => {
		if (event.message.role !== "assistant" || !event.message.usage) return;

		const input = tokenCount(event.message.usage.input);
		const output = tokenCount(event.message.usage.output);
		const total = tokenCount(event.message.usage.totalTokens);
		if (input === undefined || output === undefined || total === undefined || total < input + output) return;

		sequence += 1;
		inputTokens += input;
		outputTokens += output;
		totalTokens += total;
		await publish();
	});

	api.on("session_shutdown", () => pendingWrite);
}
