#include <cuda.h>
#include <stdio.h>
#include <sys/time.h>
#include <sys/resource.h>

// Tipo de los datos del algoritmo
typedef int data_t;

// Prototipos 
data_t  add(const data_t a, const data_t b) { return a + b; }
data_t  sub(const data_t a, const data_t b) { return a - b; }
void    init_matrix(data_t *M, const unsigned int size, data_t(*init_op)(const data_t, const data_t), int orientation, int k);
void    run_GPU(data_t* host_A, data_t* host_B, const unsigned int n_bytes, const unsigned int BLOCKS);
void    print_matrix(data_t * const M, const unsigned int size);
double  tick();
float   verificar(int n, int k1, int k2);
void    calcular_dims(const unsigned int n, unsigned int* x_bloques, unsigned int* y_bloques, unsigned int* n_threads, int ismatrix); 

__global__ void kernel_op_1(data_t * A, data_t * B);
__global__ void kernel_op_2(data_t * M, data_t* C, const unsigned int N);

// Host function
int
main(int argc, char** argv)
{
  const unsigned int N  = (argc >= 2) ? atoi(argv[1]) : 8;
  const unsigned int BLOCKS = (argc >= 3) ? atoi(argv[2]) : 64;
  const unsigned int k1 = (argc >= 4) ? atoi(argv[3]) : 7;
  const unsigned int k2 = (argc >= 5) ? atoi(argv[4]) : 9;
  double t, resultado;
  
  // Mostrar tipo de elemento
  printf("Tamaño del elemento a procesar: %d bytes\n", sizeof(data_t));

  // En la CPU...
  // ...Aloca matrices
  t = tick();
  const unsigned int n_bytes = sizeof(data_t)*N*N;
  data_t *host_A = (data_t*) malloc(n_bytes);
  data_t *host_B = (data_t*) malloc(n_bytes);
  t = tick() - t;
  printf("Alocar matrices en mem. de CPU: %f\n", t);

  // ...Inicializa matrices
  t = tick();

  init_matrix(host_A, N, &add, 0, k1);
  init_matrix(host_B, N, &sub, 1, k2);
  t = tick() - t;
  printf("Inicializar matrices en mem. de CPU: %f\n", t);

  #ifdef DEBUG
  printf("Matriz A =====\n");
  print_matrix(host_A, N);
  printf("Matriz B =====\n");
  print_matrix(host_B, N);
  #endif

  run_GPU(host_A, host_B, N, BLOCKS);

  // Verificacion de resultados
  #ifdef DEBUG
  printf("Resultado parcial =====\n");
  print_matrix(host_A, N);
  #endif

  //Paso final: dividir la suma
  resultado = host_A[0]/((float)N*N);
  printf("A[0] ===== %d\n", host_A[0]);

  t = tick();
  free(host_A);
  free(host_B);
  t = tick() - t;
  printf("Liberacion de  mem. CPU: %f\n", t);

  printf("\x1B[33mResultado final  =====>>>  %f\x1B[0m\n", resultado);
  if (resultado == verificar (N, k1, k2))
    printf("\x1B[32mVerificación: %f == %f\x1B[0m\n", resultado, verificar (N, k1, k2));
  else
    printf("\x1B[31mVerificación: %f == %f\x1B[0m\n", resultado, verificar (N, k1, k2));
  return 0;
}

void 
run_GPU(data_t* host_A, data_t* host_B, const unsigned int N, const unsigned int BLOCKS)
{
  data_t *gpu_A, *gpu_B, *gpu_C;
  const unsigned int n_bytes = sizeof(data_t)*N*N;
  unsigned int x_bloques, y_bloques, n_threads;
  double t;

  // Aloca memoria en GPU
  t = tick();
  cudaMalloc((void**)&gpu_A, n_bytes);
  cudaMalloc((void**)&gpu_B, n_bytes);
  cudaMalloc((void**)&gpu_C, n_bytes/N);
  t = tick() - t;
  printf("Alocar matrices en mem. de GPU: %f\n", t);

  // Copia los datos desde el host a la GPU
  t = tick();
  cudaMemcpy(gpu_A, host_A, n_bytes, cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_B, host_B, n_bytes, cudaMemcpyHostToDevice);
  t = tick() - t;
  printf("Copia de datos desde mem. CPU hacia mem. GPU: %f\n", t);

  // Configura el tamaño de los grids y los bloques
  n_threads = BLOCKS;
  
  calcular_dims(N, &x_bloques, &y_bloques, &n_threads, 1);
  dim3 dimGrid(x_bloques, y_bloques);   
  dim3 dimBlock(n_threads);
 
  n_threads = BLOCKS;
  calcular_dims(N, &x_bloques, &y_bloques, &n_threads, 0);
  dim3 ndimGrid(x_bloques, y_bloques);   
  dim3 ndimBlock(n_threads); 
  
  // Invoca al kernel
  t = tick();
  kernel_op_1<<< dimGrid, dimBlock >>>(gpu_A, gpu_B);
  cudaThreadSynchronize();
  //el segundo kernel usa shared mem del tamaño del bloque
  kernel_op_2<<< ndimGrid, ndimBlock, n_threads*sizeof(data_t) >>>(gpu_A, gpu_C, N);
  cudaThreadSynchronize();
  
  t = tick() - t;
  printf("\x1B[33mEjecucion del kernel de GPU: %f\x1B[0m\n", t);

  // Recupera los resultados, guardandolos en el host
  t = tick();
  cudaMemcpy(host_A, gpu_A, n_bytes, cudaMemcpyDeviceToHost);
  data_t* host_C = (data_t*) malloc(n_bytes/N);
  cudaMemcpy(host_C, gpu_C, n_bytes/N, cudaMemcpyDeviceToHost);
  host_A[0] = 0;
  for(int i=0; i<N; i++) host_A[0] += host_C[i];
  free(host_C);

  t = tick() - t;
  printf("Copia de datos desde mem. GPU hacia mem. CPU: %f\n", t);

  // Libera la memoria alocada en la GPU
  t = tick();
  cudaFree(gpu_A);
  cudaFree(gpu_B);
  cudaFree(gpu_C);
  t = tick() - t;
  printf("Liberar mem. de GPU: %f\n", t);
}

// Los kernels que ejecutaran por cada hilo de la GPU
__global__ void kernel_op_1(data_t *A, data_t *B) {
  unsigned long int block_id =  blockIdx.y * gridDim.x + blockIdx.x;
  unsigned long int global_id = block_id * blockDim.x + threadIdx.x;

  A[global_id] = (A[global_id] - B[global_id]) * (A[global_id] - B[global_id]);
}


__global__ void kernel_op_2(data_t *M, data_t *C, const unsigned int N) {
  unsigned long int block_id =  blockIdx.y * gridDim.x + blockIdx.x;
  unsigned long int global_id = block_id * blockDim.x + threadIdx.x;
  unsigned int i;
  extern __shared__ data_t S[]; //arreglo en shared mem
  S[threadIdx.x] = 0;
  for (i = 0; i < N; i++)
  	S[threadIdx.x] += M[global_id + (N * i)];
  C[global_id] = S[threadIdx.x];
}

// Funcion para la inicializacion de las matrices
void init_matrix(data_t *M, const unsigned int size, data_t(*init_op)(const data_t, const data_t), int orientation, int k ){
  unsigned int i,j;
  for (i=0; i<size; i++) {
    for (j=0; j<size; j++) {
      if ((orientation == 0) && (i==j)){
        M[i*size + j] = k;
      }
      if ((orientation == 1) && ((size-i-1) == j)){
        M[i*size + j] = k;
      }
    }
  }
}

// Impresion de matriz
void print_matrix(data_t * const M, const unsigned int size) {
  int i,j;
  for (i = 0; i < size; i++) {
    for (j = 0; j < size; j++)
        printf("%8d ", M[i*size+j]); 
    printf("\n");
  }
}

// Para medir los tiempos
double tick(){
  double sec;
  struct timeval tv;

  gettimeofday(&tv,NULL);
  sec = tv.tv_sec + tv.tv_usec/1000000.0;
  return sec;
}

float verificar(int n, int k1, int k2){
/*k1=7
    k2=9
    n=8
    (n*(k1*k1+k2*k2))/(n**2.0)
  */
	return (n*(k1*k1+k2*k2))/(float)(n*n);
}

void calcular_dims(const unsigned int n, unsigned int* x_bloques,unsigned int* y_bloques, unsigned int* n_threads, int ismatrix) {
	int N = (ismatrix) ? n*n : n ;
        *x_bloques = ((N)/(*n_threads));
	if (*x_bloques == 0){
		*x_bloques = 1;
	}
	if (*n_threads > 1024) {
		printf("\x1B[31mWARNING: Número de threads mayor al soportado por la placa!!\x1B[0m\n");
	}
	*y_bloques = 1;
	if (*x_bloques > 65535) {
		double n = *x_bloques / 65535.0;
		unsigned int i;
		for (i = 1; i < n; i *= 2);
		*y_bloques = i;
		*x_bloques /= *y_bloques;
	}
}  
