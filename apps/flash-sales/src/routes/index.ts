import { Router } from "express";
import { CheckoutController } from "../controllers/CheckoutController";
import { ExportController } from "../controllers/ExportController";
import { liveness, readiness } from "../controllers/HealthController";
import { metricsController } from "../middlewares/metricsMiddleware";

const router = Router();
const checkoutController = new CheckoutController();
const exportController = new ExportController();

router.post("/checkout", (req, res, next) => checkoutController.handle(req, res).catch(next));
router.post("/tickets/export", (req, res, next) => exportController.handle(req, res).catch(next));
router.get("/health", liveness);
router.get("/ready", readiness);
router.get("/metrics", metricsController);

export { router };
