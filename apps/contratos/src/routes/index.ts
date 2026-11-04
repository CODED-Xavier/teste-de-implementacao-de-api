import { Router } from "express";
import { ContractController } from "../controllers/ContractController";
import { liveness, readiness } from "../controllers/HealthController";
import { metricsController } from "../middlewares/metricsMiddleware";

const router = Router();
const contractController = new ContractController();

router.post("/contracts", (req, res, next) => contractController.handle(req, res).catch(next));
router.get("/health", liveness);
router.get("/ready", readiness);
router.get("/metrics", metricsController);

export { router };
