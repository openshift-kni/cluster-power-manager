package power

import (
	"fmt"
)

type poolImpl struct {
	name         string
	cpus         CPUList
	host         Host
	powerProfile Profile
}

type Pool interface {
	Name() string
	Cpus() *CPUList

	SetCPUIDs(cpuIDs []uint) error

	Remove() error

	MoveCpus(cpus CPUList) error
	MoveCPUIDs(cpuIDs []uint) error

	SetPowerProfile(profile Profile) error
	GetPowerProfile() Profile

	// private interface members
	getHost() Host
	isExclusive() bool
	setCpus(requestedCpus CPUList) error
}

func moveCpus(target Pool, cpus CPUList) error {
	for _, cpu := range cpus {
		if err := cpu.setPool(target); err != nil {
			return err
		}
	}
	return nil
}

func (pool *poolImpl) Name() string {
	return pool.name
}

func (pool *poolImpl) Cpus() *CPUList {
	return &pool.cpus
}

func (pool *poolImpl) SetCPUIDs([]uint) error {
	panic("virtual")
} // virtual

func (pool *poolImpl) setCpus(CPUList) error {
	// virtual function to be overwritten by exclusivePoolType, sharedPoolType and ReservedPoolType
	panic("scuffed")
} // virtual

func (pool *poolImpl) MoveCpus(cpus CPUList) error {
	panic("virtual")
}

func (pool *poolImpl) MoveCPUIDs(cpuIDs []uint) error {
	panic("virtual")
}

func (pool *poolImpl) Remove() error {
	panic("'virtual' function")
} // virtual

func (pool *poolImpl) SetPowerProfile(profile Profile) error {
	unlock := lockHostMutex(pool.host.getHostMutex(), "pool", pool.name)
	defer unlock()

	pool.powerProfile = profile
	for _, cpu := range pool.cpus {
		if err := cpu.consolidate(); err != nil {
			return err
		}
	}
	return nil
}

func (pool *poolImpl) GetPowerProfile() Profile {
	return pool.powerProfile
}

func (pool *poolImpl) getHost() Host {
	return pool.host
}

func (pool *poolImpl) isExclusive() bool {
	return false
}

type sharedPoolType struct {
	poolImpl
}

func (sharedPool *sharedPoolType) MoveCPUIDs(cpuIDs []uint) error {
	unlock := lockHostMutex(sharedPool.host.getHostMutex(), "pool", sharedPool.name)
	defer unlock()

	cpus, err := sharedPool.host.GetAllCpus().ManyByIDs(cpuIDs)
	if err != nil {
		return err
	}
	return moveCpus(sharedPool, cpus)
}
func (sharedPool *sharedPoolType) MoveCpus(cpus CPUList) error {
	unlock := lockHostMutex(sharedPool.host.getHostMutex(), "pool", sharedPool.name)
	defer unlock()

	return moveCpus(sharedPool, cpus)
}
func (sharedPool *sharedPoolType) SetCPUIDs(cpuIDs []uint) error {
	unlock := lockHostMutex(sharedPool.host.getHostMutex(), "pool", sharedPool.name)
	defer unlock()

	cores, err := sharedPool.host.GetAllCpus().ManyByIDs(cpuIDs)
	if err != nil {
		return fmt.Errorf("cpuCore out of range: %w", err)
	}
	return sharedPool.setCpus(cores)
}

// setCpus places the requested CPUs in the shared pool and moves unwanted CPUs
// from the shared pool to the reserved pool.
func (sharedPool *sharedPoolType) setCpus(requestedCores CPUList) error {
	for _, cpu := range *sharedPool.host.GetAllCpus() {
		if requestedCores.Contains(cpu) {
			err := cpu.setPool(sharedPool)
			if err != nil {
				return err
			}
		} else if cpu.getPool() == sharedPool { // move cpus we don't want if the shared pool to reserved, don't touch any exclusive
			err := cpu.setPool(sharedPool.host.GetReservedPool())
			if err != nil {
				return err
			}
		}
	}
	return nil
}
func (sharedPool *sharedPoolType) Remove() error {
	return fmt.Errorf("shared pool canot be removed")
}

type reservedPoolType struct {
	poolImpl
}

func (reservedPool *reservedPoolType) MoveCPUIDs(cpuIDs []uint) error {
	unlock := lockHostMutex(reservedPool.host.getHostMutex(), "pool", reservedPool.name)
	defer unlock()

	cpus, err := reservedPool.host.GetAllCpus().ManyByIDs(cpuIDs)
	if err != nil {
		return err
	}
	return moveCpus(reservedPool, cpus)
}
func (reservedPool *reservedPoolType) MoveCpus(cpus CPUList) error {
	unlock := lockHostMutex(reservedPool.host.getHostMutex(), "pool", reservedPool.name)
	defer unlock()

	return moveCpus(reservedPool, cpus)
}
func (reservedPool *reservedPoolType) SetCPUIDs(cpuIDs []uint) error {
	unlock := lockHostMutex(reservedPool.host.getHostMutex(), "pool", reservedPool.name)
	defer unlock()

	cpus, err := reservedPool.host.GetAllCpus().ManyByIDs(cpuIDs)
	if err != nil {
		return fmt.Errorf("cpuCore out of range: %w", err)
	}
	return reservedPool.setCpus(cpus)
}
func (reservedPool *reservedPoolType) SetPowerProfile(Profile) error {
	return fmt.Errorf("cannot set power profile for reserved pool")
}

// setCpus replaces the reserved pool's CPU membership.
func (reservedPool *reservedPoolType) setCpus(cores CPUList) error {
	/*
		case 1: cpu in any exclusive pool, not passed matching IDs -> untouched
		case 2: cpu in any exclusive pool, matching passed IDs -> error

		case 3: cpu in shared pool, not matching IDs passed -> untouched
		case 4: cpu in shared pool, IDs match passed -> move to reserved

		case 5: cpu in reserved pool, not matching IDs passed -> move to shared
		case 6: cpu in reserved pool, IDs match passed -> untouched
	*/

	sharedPool := reservedPool.host.GetSharedPool()

	for _, cpu := range *reservedPool.host.GetAllCpus() {
		if cores.Contains(cpu) { // case 2,4, 6
			if cpu.getPool().isExclusive() { // case 2
				return fmt.Errorf("cpus cannot be moved directly from exclusive to reserved pool")
			}
			err := cpu.setPool(reservedPool) // case 4
			if err != nil {
				return err
			}
		} else { // case 1,3,5
			if cpu.getPool() == reservedPool { // case 5
				err := cpu.setPool(sharedPool)
				if err != nil {
					return err
				}
			}
			continue // 1,3 do nothing
		}
	}
	return nil
}

func (reservedPool *reservedPoolType) Remove() error {
	return fmt.Errorf("reserved Pool cannot be removed")
}

type exclusivePoolType struct {
	poolImpl
}

func (pool *exclusivePoolType) MoveCPUIDs(cpuIDs []uint) error {
	unlock := lockHostMutex(pool.host.getHostMutex(), "pool", pool.name)
	defer unlock()

	cpus, err := pool.host.GetAllCpus().ManyByIDs(cpuIDs)
	if err != nil {
		return err
	}
	return moveCpus(pool, cpus)
}
func (pool *exclusivePoolType) MoveCpus(cpus CPUList) error {
	unlock := lockHostMutex(pool.host.getHostMutex(), "pool", pool.name)
	defer unlock()

	return moveCpus(pool, cpus)
}
func (pool *exclusivePoolType) SetCPUIDs(cpuIDs []uint) error {
	unlock := lockHostMutex(pool.host.getHostMutex(), "pool", pool.name)
	defer unlock()

	cpus, err := pool.host.GetAllCpus().ManyByIDs(cpuIDs)
	if err != nil {
		return fmt.Errorf("cpuCore out of range: %w", err)
	}
	return pool.setCpus(cpus)
}

// setCpus replaces the exclusive pool's CPU membership.
func (pool *exclusivePoolType) setCpus(requestedCores CPUList) error {
	for _, cpu := range *pool.host.GetAllCpus() {
		if requestedCores.Contains(cpu) {
			err := cpu.setPool(pool)
			if err != nil {
				return err
			}
		} else {
			if cpu.getPool() != pool {
				continue
			}
			err := cpu.setPool(pool.host.GetSharedPool())
			if err != nil {
				return err
			}
		}
	}
	return nil
}

func (pool *exclusivePoolType) Remove() error {
	unlock := lockHostMutex(pool.host.getHostMutex(), "pool", pool.name)
	defer unlock()

	if err := pool.setCpus(CPUList{}); err != nil {
		return err
	}
	return pool.host.GetAllExclusivePools().remove(pool)
}

func (pool *exclusivePoolType) isExclusive() bool {
	return true
}

type PoolList []Pool

func (pools *PoolList) IndexOf(pool Pool) int {
	for i, p := range *pools {
		if p == pool {
			return i
		}
	}
	return -1
}

func (pools *PoolList) IndexOfName(name string) int {
	for i, p := range *pools {
		if p.Name() == name {
			return i
		}
	}
	return -1
}

func (pools *PoolList) Contains(pool Pool) bool {
	if pools.IndexOf(pool) < 0 {
		return false
	} else {
		return true
	}
}

func (pools *PoolList) remove(pool Pool) error {
	index := pools.IndexOf(pool)
	if index < 0 {
		return fmt.Errorf("pool %s not in on host", pool.Name())
	}
	size := len(*pools) - 1
	(*pools)[index] = (*pools)[size]
	*pools = (*pools)[:size]
	return nil
}

func (pools *PoolList) add(pool Pool) {
	*pools = append(*pools, pool)
}

func (pools *PoolList) ByName(name string) Pool {
	index := pools.IndexOfName(name)
	if index < 0 {
		return nil
	}
	return (*pools)[index]
}
