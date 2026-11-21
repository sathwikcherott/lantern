import java.io.PrintStream;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryUsage;
import com.sun.management.OperatingSystemMXBean;

public final class LanternMetrics {
    public static void premain(String arguments) {
        PrintStream output = System.out;
        Thread sampler = new Thread(() -> {
            var memory = ManagementFactory.getMemoryMXBean();
            var os = ManagementFactory.getPlatformMXBean(OperatingSystemMXBean.class);
            long lastTime = System.nanoTime();
            long lastCpu = os.getProcessCpuTime();
            while (true) {
                try {
                    Thread.sleep(2000);
                } catch (InterruptedException stopped) {
                    return;
                }
                long time = System.nanoTime();
                long cpu = os.getProcessCpuTime();
                MemoryUsage heap = memory.getHeapMemoryUsage();
                if (cpu >= lastCpu && lastCpu >= 0 && time > lastTime) {
                    double percent = 100.0 * (cpu - lastCpu) / (time - lastTime);
                    output.println("LANTERN_METRICS " + percent + " " + heap.getUsed() + " " + heap.getMax());
                }
                lastCpu = cpu;
                lastTime = time;
            }
        }, "Lantern metrics");
        sampler.setDaemon(true);
        sampler.start();
    }
}
