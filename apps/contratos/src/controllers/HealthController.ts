import { Request, Response } from "express";
import { AppDataSource } from "../config/database";
import { redis } from "../config/redis";

/** Liveness: o processo está vivo e o event loop responde. Não depende de nada externo. */
export function liveness(_req: Request, res: Response) {
  res.status(200).json({ status: "ok" });
}

/** Readiness: a instância só recebe tráfego se PostgreSQL e Redis estiverem acessíveis. */
export async function readiness(_req: Request, res: Response) {
  try {
    if (!AppDataSource.isInitialized) throw new Error("database not initialized");
    await AppDataSource.query("SELECT 1");
    if (redis.status !== "ready") throw new Error(`redis ${redis.status}`);
    res.status(200).json({ status: "ready" });
  } catch (err: any) {
    res.status(503).json({ status: "not_ready", reason: err.message });
  }
}
