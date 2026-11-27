#include <ableton/Link.hpp>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string>
#include <string_view>

int main()
{
  const char* gate = std::getenv("APERTURECUE_LINK_DIAGNOSTIC");
  if (!gate || std::string_view{gate} != "loopback-only")
  {
    return 2;
  }
  ableton::Link link{120};
  link.enable(true);
  std::cout << std::setprecision(15);
  std::cout << "ready" << std::endl;
  std::string command;
  while (std::cin >> command)
  {
    if (command == "quit")
    {
      break;
    }
    if (command == "tempo")
    {
      double tempo = 0;
      if (!(std::cin >> tempo) || tempo < 20 || tempo > 300) return 2;
      auto state = link.captureAppSessionState();
      state.setTempo(tempo, link.clock().micros());
      link.commitAppSessionState(state);
    }
    else if (command == "sample")
    {
      int64_t time = 0;
      if (!(std::cin >> time)) return 2;
      const auto now = time > 0 ? std::chrono::microseconds{time} : link.clock().micros();
      const auto state = link.captureAppSessionState();
      std::cout << link.numPeers() << ' ' << now.count() << ' ' << state.tempo() << ' '
                << state.beatAtTime(now, 4) << ' ' << state.phaseAtTime(now, 4) << std::endl;
    }
    else
    {
      return 2;
    }
  }
  link.enable(false);
}
