"""PyInstaller 打包用的入口文件。

为什么不直接用 src/main.py 当入口?
  因为 src 里全部是相对导入 (from . import xxx)。
  PyInstaller 把入口文件当顶层模块,从顶层跑 `from . import` 会抛
  "attempted relative import with no known parent package"。

解决办法:
  这个 run.py 在仓库根,被 PyInstaller 当入口;
  它把仓库根加进 sys.path,然后 import src.main 再调用 main()。
  这样 src 还是一个正常的 Python 包,相对导入都能跑通。
"""
import os
import sys

# 把仓库根目录加进 sys.path,方便 src 包被找到
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from src.main import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
