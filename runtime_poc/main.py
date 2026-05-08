"""Entry point: python -m runtime_poc.main"""

import time

from runtime_poc.demo_game import build_demo


def main() -> None:
    orchestrator = build_demo()

    print("=== Runtime POC: 100-frame simulation ===")

    # Let background asset load complete before first frame
    time.sleep(0.1)

    for frame in range(100):
        orchestrator.run_frame(dt=1.0 / 60.0)

    # Cleanup
    orchestrator.job_system.shutdown()
    orchestrator.background.shutdown()

    print("\n=== Simulation complete ===")


if __name__ == "__main__":
    main()
