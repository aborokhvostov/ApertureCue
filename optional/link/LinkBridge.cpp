#include <ableton/Link.hpp>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <locale>
#include <string_view>
#include <thread>

namespace
{
volatile std::sig_atomic_t stopping = 0;
void stop(int) { stopping = 1; }
constexpr double quantum = 4;
}

int main(int argc, char** argv)
{
#if defined(APERTURECUE_LINK_TEST)
  const char* gate = std::getenv("APERTURECUE_LINK_DIAGNOSTIC");
  if (argc != 2 || std::string_view{argv[1]} != "--test-loopback"
      || !gate || std::string_view{gate} != "loopback-only")
#else
  if (argc != 2 || std::string_view{argv[1]} != "--connect")
#endif
  {
    return 2;
  }

  std::signal(SIGINT, stop);
  std::signal(SIGTERM, stop);
  std::signal(SIGPIPE, SIG_IGN);
  std::cout.imbue(std::locale::classic());
  std::cout << std::setprecision(15);
  try
  {
    ableton::Link link{120};
    link.enableStartStopSync(false);
    link.enable(true);
    uint64_t sequence = 0;
    while (!stopping && std::cout.good())
    {
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{16};
      const auto state = link.captureAppSessionState();
      const auto time = link.clock().micros();
      std::cout << "{\"version\":1,\"sequence\":" << ++sequence
                << ",\"hostMicros\":" << time.count() << ",\"peers\":" << link.numPeers()
                << ",\"tempo\":" << state.tempo() << ",\"beat\":" << state.beatAtTime(time, quantum)
                << ",\"phase\":" << state.phaseAtTime(time, quantum) << "}" << std::endl;
      std::this_thread::sleep_until(deadline);
    }
    link.enable(false);
  }
  catch (const std::exception& error)
  {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
