"""让 `python -m src` 可跑。"""
from .main import main
import sys

if __name__ == "__main__":
    sys.exit(main())
