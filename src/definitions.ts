export interface SocketsPlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
