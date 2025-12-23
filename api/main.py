from fastapi import FastAPI, APIRouter
from dotenv import load_dotenv
from routers.journal_router import router as journal_router
import logging


load_dotenv()
router = APIRouter()

# TODO: Setup basic console logging
# Hint: Use logging.basicConfig() with level=logging.INFO
# Steps:
# 1. Configure logging with basicConfig()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
# 2. Set level to logging.INFO
# 3. Add console handler
logger = logging.getLogger(__name__)
# 4. Test by adding a log message when the app starts
logger.info("journal api system initializing...")

app = FastAPI(title="Journal API", description="A simple journal API for tracking daily work, struggles, and intentions")
app.include_router(journal_router)

@router.get("/")
async def get_all_entries():
    return {"message":"hello from CI/CD Pipeline!"}

    