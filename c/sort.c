int main() {
    // Force the pointer to align with the start of Data Memory (Physical Address 0x00000000)
    // The 'volatile' keyword is used to prevent the compiler from optimizing away 
    // these memory accesses, ensuring every read/write hits the actual hardware DMem.
    volatile int *array = (int *)0x00000000;
    
    int i, j, swap;

    // Execute standard Bubble Sort algorithm
    // Note: On your 4-threaded CPU, each thread will execute this code 
    // independently on its own partitioned memory segment.
    for (i = 0; i < 10; i++) {
        for (j = i + 1; j < 10; j++) {
            if (array[j] < array[i]) {
                swap = array[j];
                array[j] = array[i];
                array[i] = swap;
            }
        }
    }
    
    // Enter an infinite loop upon completion to prevent the Program Counter (PC)
    // from wandering into undefined memory regions (preventing "code runaway").
    while(1); 
    return 0;
}