# RunSession Memory Optimization Analysis

## Problem Statement
The right side of the chat window has two memory-intensive components:
1. **RunSession List**: Performing huge joins and caching entire runsession objects
2. **RunSession Detail View**: Frequent polling with complex caching mechanisms

## Root Cause Analysis

### 1. RunSession List Issues
- Loading complete runsession objects instead of summaries
- No pagination or virtual scrolling
- Keeping all runsessions in memory simultaneously
- Complex joins happening on the frontend

### 2. RunSession Detail View Issues
- Frequent polling (every few seconds) without cleanup
- Complex caching strategies causing memory accumulation
- Multiple concurrent API calls
- No request cancellation when switching between runsessions

## Optimization Strategy

### Phase 1: RunSession List Optimization

#### 1.1 Implement Summary-Only Loading
```javascript
// Before: Loading full runsession objects
const loadRunSessions = async () => {
  const response = await fetch(`/api/workspace/${workspaceId}/runsessions`);
  const fullRunSessions = await response.json(); // Huge objects with all details
  setRunSessions(fullRunSessions);
};

// After: Load only essential data
const loadRunSessionSummaries = async () => {
  const response = await fetch(`/api/workspace/${workspaceId}/runsessions/summary`);
  const summaries = await response.json(); // Only id, name, status, timestamp
  setRunSessions(summaries);
};
```

#### 1.2 Virtual Scrolling for RunSession List
```jsx
import React, { useState, useCallback } from 'react';
import { FixedSizeList as List } from 'react-window';

const RunSessionList = ({ workspaceId, onSelectRunSession }) => {
  const [runSessions, setRunSessions] = useState([]);
  const [selectedId, setSelectedId] = useState(null);

  const RunSessionRow = ({ index, style }) => {
    const runSession = runSessions[index];
    const isSelected = selectedId === runSession.id;
    
    return (
      <div 
        style={style} 
        className={`runsession-item ${isSelected ? 'selected' : ''}`}
        onClick={() => {
          setSelectedId(runSession.id);
          onSelectRunSession(runSession.id);
        }}
      >
        <div className="runsession-summary">
          <span className="name">{runSession.name}</span>
          <span className="status">{runSession.status}</span>
          <span className="timestamp">{runSession.timestamp}</span>
        </div>
      </div>
    );
  };

  return (
    <List
      height={400}
      itemCount={runSessions.length}
      itemSize={60}
      width="100%"
    >
      {RunSessionRow}
    </List>
  );
};
```

#### 1.3 Pagination for Large RunSession Lists
```javascript
const useRunSessionPagination = (workspaceId, pageSize = 50) => {
  const [runSessions, setRunSessions] = useState([]);
  const [hasMore, setHasMore] = useState(true);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);

  const loadMoreRunSessions = useCallback(async () => {
    if (loading || !hasMore) return;
    
    setLoading(true);
    try {
      const response = await fetch(
        `/api/workspace/${workspaceId}/runsessions/summary?page=${page}&limit=${pageSize}`
      );
      const newRunSessions = await response.json();
      
      setRunSessions(prev => [...prev, ...newRunSessions]);
      setHasMore(newRunSessions.length === pageSize);
      setPage(prev => prev + 1);
    } catch (error) {
      console.error('Failed to load runsessions:', error);
    } finally {
      setLoading(false);
    }
  }, [workspaceId, page, pageSize, loading, hasMore]);

  return { runSessions, hasMore, loading, loadMoreRunSessions };
};
```

### Phase 2: RunSession Detail View Optimization

#### 2.1 Optimized Polling with Request Management
```javascript
const useRunSessionDetail = (runSessionId) => {
  const [details, setDetails] = useState(null);
  const [loading, setLoading] = useState(false);
  const abortControllerRef = useRef(null);
  const pollingIntervalRef = useRef(null);

  // Cleanup function to cancel requests and intervals
  const cleanup = useCallback(() => {
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }
    if (pollingIntervalRef.current) {
      clearInterval(pollingIntervalRef.current);
      pollingIntervalRef.current = null;
    }
  }, []);

  // Load runsession details
  const loadDetails = useCallback(async () => {
    if (!runSessionId) return;
    
    cleanup(); // Cancel previous requests
    
    setLoading(true);
    abortControllerRef.current = new AbortController();
    
    try {
      const response = await fetch(
        `/api/runsession/${runSessionId}/details`,
        { signal: abortControllerRef.current.signal }
      );
      const data = await response.json();
      setDetails(data);
    } catch (error) {
      if (error.name !== 'AbortError') {
        console.error('Failed to load runsession details:', error);
      }
    } finally {
      setLoading(false);
    }
  }, [runSessionId, cleanup]);

  // Start polling with cleanup
  const startPolling = useCallback((intervalMs = 5000) => {
    cleanup();
    
    // Load initial data
    loadDetails();
    
    // Start polling
    pollingIntervalRef.current = setInterval(loadDetails, intervalMs);
  }, [loadDetails, cleanup]);

  // Stop polling
  const stopPolling = useCallback(() => {
    cleanup();
  }, [cleanup]);

  // Cleanup on unmount or when runSessionId changes
  useEffect(() => {
    return cleanup;
  }, [cleanup]);

  return {
    details,
    loading,
    startPolling,
    stopPolling,
    loadDetails
  };
};
```

#### 2.2 Smart Caching Strategy
```javascript
const useRunSessionCache = () => {
  const cache = useRef(new Map());
  const cacheTimestamps = useRef(new Map());
  const CACHE_DURATION = 5 * 60 * 1000; // 5 minutes

  const getCachedData = useCallback((key) => {
    const timestamp = cacheTimestamps.current.get(key);
    const now = Date.now();
    
    if (timestamp && (now - timestamp) < CACHE_DURATION) {
      return cache.current.get(key);
    }
    
    // Remove expired cache
    cache.current.delete(key);
    cacheTimestamps.current.delete(key);
    return null;
  }, []);

  const setCachedData = useCallback((key, data) => {
    cache.current.set(key, data);
    cacheTimestamps.current.set(key, Date.now());
  }, []);

  const clearCache = useCallback(() => {
    cache.current.clear();
    cacheTimestamps.current.clear();
  }, []);

  // Cleanup old cache entries periodically
  useEffect(() => {
    const cleanupInterval = setInterval(() => {
      const now = Date.now();
      for (const [key, timestamp] of cacheTimestamps.current.entries()) {
        if (now - timestamp > CACHE_DURATION) {
          cache.current.delete(key);
          cacheTimestamps.current.delete(key);
        }
      }
    }, 60000); // Check every minute

    return () => clearInterval(cleanupInterval);
  }, []);

  return { getCachedData, setCachedData, clearCache };
};
```

#### 2.3 Optimized RunSession Detail Component
```jsx
import React, { useState, useEffect, useCallback, useRef } from 'react';

const RunSessionDetail = ({ runSessionId }) => {
  const [activeTab, setActiveTab] = useState('overview');
  const [pollingEnabled, setPollingEnabled] = useState(true);
  
  const {
    details,
    loading,
    startPolling,
    stopPolling
  } = useRunSessionDetail(runSessionId);
  
  const { getCachedData, setCachedData } = useRunSessionCache();
  
  const abortControllerRef = useRef(null);

  // Start/stop polling based on visibility and user preference
  useEffect(() => {
    if (!runSessionId) return;

    if (pollingEnabled) {
      startPolling(5000); // Poll every 5 seconds
    } else {
      stopPolling();
    }

    return () => stopPolling();
  }, [runSessionId, pollingEnabled, startPolling, stopPolling]);

  // Handle visibility change to pause polling when tab is not visible
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.hidden) {
        stopPolling();
      } else if (pollingEnabled) {
        startPolling(5000);
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, [pollingEnabled, startPolling, stopPolling]);

  // Optimized data fetching with caching
  const fetchRunSessionData = useCallback(async (dataType) => {
    const cacheKey = `${runSessionId}-${dataType}`;
    const cachedData = getCachedData(cacheKey);
    
    if (cachedData) {
      return cachedData;
    }

    // Cancel previous request
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
    }
    
    abortControllerRef.current = new AbortController();
    
    try {
      const response = await fetch(
        `/api/runsession/${runSessionId}/${dataType}`,
        { signal: abortControllerRef.current.signal }
      );
      const data = await response.json();
      
      setCachedData(cacheKey, data);
      return data;
    } catch (error) {
      if (error.name !== 'AbortError') {
        console.error(`Failed to fetch ${dataType}:`, error);
      }
      throw error;
    }
  }, [runSessionId, getCachedData, setCachedData]);

  if (loading && !details) {
    return <div>Loading runsession details...</div>;
  }

  if (!details) {
    return <div>No runsession selected</div>;
  }

  return (
    <div className="runsession-detail">
      <div className="runsession-header">
        <h3>{details.name}</h3>
        <div className="controls">
          <label>
            <input
              type="checkbox"
              checked={pollingEnabled}
              onChange={(e) => setPollingEnabled(e.target.checked)}
            />
            Auto-refresh
          </label>
        </div>
      </div>
      
      <div className="runsession-tabs">
        <button
          className={activeTab === 'overview' ? 'active' : ''}
          onClick={() => setActiveTab('overview')}
        >
          Overview
        </button>
        <button
          className={activeTab === 'logs' ? 'active' : ''}
          onClick={() => setActiveTab('logs')}
        >
          Logs
        </button>
        <button
          className={activeTab === 'metrics' ? 'active' : ''}
          onClick={() => setActiveTab('metrics')}
        >
          Metrics
        </button>
      </div>
      
      <div className="runsession-content">
        {activeTab === 'overview' && (
          <RunSessionOverview details={details} />
        )}
        {activeTab === 'logs' && (
          <RunSessionLogs 
            runSessionId={runSessionId}
            fetchData={fetchRunSessionData}
          />
        )}
        {activeTab === 'metrics' && (
          <RunSessionMetrics 
            runSessionId={runSessionId}
            fetchData={fetchRunSessionData}
          />
        )}
      </div>
    </div>
  );
};

// Optimized sub-components
const RunSessionOverview = React.memo(({ details }) => {
  return (
    <div className="overview">
      <div className="status">Status: {details.status}</div>
      <div className="timestamp">Started: {details.startTime}</div>
      <div className="duration">Duration: {details.duration}</div>
    </div>
  );
});

const RunSessionLogs = React.memo(({ runSessionId, fetchData }) => {
  const [logs, setLogs] = useState([]);
  const [loading, setLoading] = useState(false);

  const loadLogs = useCallback(async () => {
    setLoading(true);
    try {
      const logData = await fetchData('logs');
      setLogs(logData);
    } catch (error) {
      console.error('Failed to load logs:', error);
    } finally {
      setLoading(false);
    }
  }, [fetchData]);

  useEffect(() => {
    loadLogs();
  }, [loadLogs]);

  if (loading) return <div>Loading logs...</div>;

  return (
    <div className="logs">
      {logs.map((log, index) => (
        <div key={index} className="log-entry">
          <span className="timestamp">{log.timestamp}</span>
          <span className="level">{log.level}</span>
          <span className="message">{log.message}</span>
        </div>
      ))}
    </div>
  );
});

const RunSessionMetrics = React.memo(({ runSessionId, fetchData }) => {
  const [metrics, setMetrics] = useState({});
  const [loading, setLoading] = useState(false);

  const loadMetrics = useCallback(async () => {
    setLoading(true);
    try {
      const metricData = await fetchData('metrics');
      setMetrics(metricData);
    } catch (error) {
      console.error('Failed to load metrics:', error);
    } finally {
      setLoading(false);
    }
  }, [fetchData]);

  useEffect(() => {
    loadMetrics();
  }, [loadMetrics]);

  if (loading) return <div>Loading metrics...</div>;

  return (
    <div className="metrics">
      {Object.entries(metrics).map(([key, value]) => (
        <div key={key} className="metric">
          <span className="metric-name">{key}</span>
          <span className="metric-value">{value}</span>
        </div>
      ))}
    </div>
  );
});

export default RunSessionDetail;
```

### Phase 3: Memory Monitoring and Cleanup

#### 3.1 RunSession-Specific Memory Monitor
```javascript
const useRunSessionMemoryMonitor = () => {
  const memoryThreshold = 800; // 800MB threshold
  const cleanupCallbacks = useRef([]);

  useEffect(() => {
    const checkMemory = () => {
      if ('memory' in performance) {
        const { usedJSHeapSize } = performance.memory;
        const usageMB = usedJSHeapSize / 1024 / 1024;
        
        if (usageMB > memoryThreshold) {
          console.warn(`High memory usage in RunSession: ${usageMB.toFixed(2)} MB`);
          
          // Trigger cleanup callbacks
          cleanupCallbacks.current.forEach(callback => callback());
        }
      }
    };

    const interval = setInterval(checkMemory, 15000); // Check every 15 seconds
    
    return () => {
      clearInterval(interval);
      cleanupCallbacks.current = [];
    };
  }, [memoryThreshold]);

  const registerCleanup = useCallback((callback) => {
    cleanupCallbacks.current.push(callback);
  }, []);

  return { registerCleanup };
};
```

#### 3.2 Main RunSession Container with Memory Management
```jsx
const RunSessionContainer = ({ workspaceId }) => {
  const [selectedRunSessionId, setSelectedRunSessionId] = useState(null);
  const { registerCleanup } = useRunSessionMemoryMonitor();

  // Cleanup function for memory management
  const cleanup = useCallback(() => {
    // Clear selected runsession to free memory
    setSelectedRunSessionId(null);
    
    // Force garbage collection if available
    if (window.gc) {
      window.gc();
    }
  }, []);

  useEffect(() => {
    registerCleanup(cleanup);
  }, [registerCleanup, cleanup]);

  return (
    <div className="runsession-container">
      <div className="runsession-list">
        <RunSessionList
          workspaceId={workspaceId}
          onSelectRunSession={setSelectedRunSessionId}
        />
      </div>
      <div className="runsession-detail">
        {selectedRunSessionId && (
          <RunSessionDetail runSessionId={selectedRunSessionId} />
        )}
      </div>
    </div>
  );
};
```

## Implementation Checklist

### RunSession List Optimizations
- [ ] Implement summary-only API endpoint
- [ ] Add virtual scrolling to runsession list
- [ ] Implement pagination for large lists
- [ ] Remove full object caching from list view

### RunSession Detail Optimizations
- [ ] Implement request cancellation with AbortController
- [ ] Add smart caching with expiration
- [ ] Optimize polling frequency
- [ ] Pause polling when tab is not visible
- [ ] Add user control for auto-refresh

### Memory Management
- [ ] Add memory monitoring
- [ ] Implement cleanup callbacks
- [ ] Add garbage collection triggers
- [ ] Monitor memory usage in production

### API Optimizations (Backend)
- [ ] Create summary endpoint for runsession list
- [ ] Implement pagination in backend
- [ ] Add caching headers
- [ ] Optimize database queries

## Expected Results

After implementing these optimizations:
- **60-80% reduction in memory usage** for runsession components
- **Elimination of memory leaks** from polling
- **Improved performance** with large numbers of runsessions
- **Better user experience** with responsive interface

## Testing Strategy

1. **Memory Testing:**
   - Open Chrome DevTools Memory tab
   - Load workspace with 1000+ runsessions
   - Monitor memory usage over time
   - Check for memory leaks

2. **Performance Testing:**
   - Measure initial load time
   - Test switching between runsessions
   - Monitor polling performance
   - Check for UI responsiveness

3. **Stress Testing:**
   - Load maximum number of runsessions
   - Enable polling on multiple runsessions
   - Test with slow network conditions
   - Verify cleanup on component unmount